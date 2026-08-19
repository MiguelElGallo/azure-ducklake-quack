#!/usr/bin/env bash
set -euo pipefail

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to deploy unless every tracked and untracked release file is committed." >&2
  exit 1
fi
git rev-parse --verify HEAD >/dev/null

subscription_id=$(azd env get-value AZURE_SUBSCRIPTION_ID)
environment_name=$(azd env get-value AZURE_ENV_NAME)
location=$(azd env get-value AZURE_LOCATION)
resource_group="rg-azure-ducklake-quack-${environment_name}"
az account set --subscription "$subscription_id"

# All read-only collision, provider, location, and SKU checks happen before the
# one approved subscription mutation (Microsoft.Network registration).
if [[ "$(az group exists --name "$resource_group")" == "true" ]]; then
  project_tag=$(az group show --name "$resource_group" --query 'tags.project' -o tsv)
  owner_tag=$(az group show --name "$resource_group" --query 'tags."azd-env-name"' -o tsv)
  if [[ "$project_tag" != "azure-ducklake-quack" || "$owner_tag" != "$environment_name" ]]; then
    echo "Refusing to adopt pre-existing resource group: ${resource_group}" >&2
    exit 1
  fi
fi

required_providers=(
  Microsoft.App
  Microsoft.Authorization
  Microsoft.ContainerRegistry
  Microsoft.DBforPostgreSQL
  Microsoft.KeyVault
  Microsoft.ManagedIdentity
  Microsoft.OperationalInsights
  Microsoft.Storage
)
for provider in "${required_providers[@]}"; do
  state=$(az provider show --namespace "$provider" --query registrationState -o tsv)
  if [[ "$state" != "Registered" ]]; then
    echo "Required provider is not registered: ${provider} (${state})" >&2
    exit 1
  fi
done

location_display_name=$(az account list-locations \
  --query "[?name=='${location}'].displayName | [0]" -o tsv)
aca_locations=$(az provider show --namespace Microsoft.App \
  --query "resourceTypes[?resourceType=='managedEnvironments'].locations | [0]" -o json)
if [[ -z "$location_display_name" ]] || ! jq -e --arg location "$location_display_name" \
  'map(ascii_downcase) | index($location | ascii_downcase) != null' <<<"$aca_locations" >/dev/null; then
  echo "Container Apps managed environments are unavailable in ${location}." >&2
  exit 1
fi
postgres_sku_count=$(az postgres flexible-server list-skus --location "$location" \
  --query "length([].supportedServerEditions[].supportedServerSkus[?name=='Standard_B1ms'][])" -o tsv)
if [[ "$postgres_sku_count" == "0" ]]; then
  echo "PostgreSQL Standard_B1ms is unavailable in ${location}." >&2
  exit 1
fi

network_state=$(az provider show --namespace Microsoft.Network --query registrationState -o tsv)
if [[ "$network_state" != "Registered" ]]; then
  az provider register --namespace Microsoft.Network --wait
fi

# Stage 1: data, identities, registry, monitoring, and the ACA environment.
azd env set AZDQ_DEPLOY_BOOTSTRAP false
azd env set AZDQ_DEPLOY_APPS false
azd provision --no-prompt

resource_group=$(azd env get-value AZURE_RESOURCE_GROUP)
aca_environment=$(azd env get-value AZURE_CONTAINER_APPS_ENVIRONMENT_NAME)
consumption_quota=$(az containerapp env list-usages \
  --name "$aca_environment" \
  --resource-group "$resource_group" \
  --query "value[?name.value=='ManagedEnvironmentConsumptionCores'] | [0].{current:currentValue,limit:limit}" \
  -o json)
# Three apps can request 1.25 cores together. Reserve another 1.25 so a later
# single-revision rollout can overlap old and new replicas without exhausting quota.
required_available_cores=2.5
if ! jq -e --argjson required "$required_available_cores" \
  '(.current | type == "number") and (.limit | type == "number") and (.limit - .current >= $required)' \
  <<<"$consumption_quota" >/dev/null; then
  echo "ACA environment lacks ${required_available_cores} available Consumption cores: ${consumption_quota}" >&2
  exit 1
fi
echo "ACA Consumption quota gate passed: ${consumption_quota}"

registry_name=$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME)
registry_server=$(azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT)
registry_id=$(az acr show --name "$registry_name" --resource-group "$resource_group" --query id -o tsv)
pull_principals=$(az identity list --resource-group "$resource_group" \
  --query "[?starts_with(name, 'id-azdq-')].principalId" -o json)
if [[ "$(jq 'length' <<<"$pull_principals")" != "4" ]]; then
  echo "Expected exactly four project managed identities before the ACR gate." >&2
  exit 1
fi
for attempt in {1..30}; do
  pull_assignments=$(az role assignment list --scope "$registry_id" -o json)
  if jq -e --argjson principals "$pull_principals" '
    [.[] | select(.roleDefinitionName == "AcrPull") | .principalId] as $actual
    | all($principals[]; . as $id | $actual | index($id) != null)
  ' <<<"$pull_assignments" >/dev/null; then
    echo "AcrPull propagation gate passed for all four managed identities."
    break
  fi
  if [[ "$attempt" == "30" ]]; then
    echo "AcrPull did not propagate to all four managed identities within five minutes." >&2
    exit 1
  fi
  echo "Waiting for AcrPull propagation (${attempt}/30)."
  sleep 10
done

revision=$(git rev-parse --short=12 HEAD)
gateway_tag="v0.2.0-${revision}"
runtime_tag="v0.2.0-${revision}"

az acr build --registry "$registry_name" --image "azdq-gateway:${gateway_tag}" --file docker/gateway.Dockerfile .
az acr build --registry "$registry_name" --image "azdq-runtime:${runtime_tag}" --file docker/runtime.Dockerfile .
gateway_digest=$(az acr repository show --name "$registry_name" --image "azdq-gateway:${gateway_tag}" --query digest -o tsv)
runtime_digest=$(az acr repository show --name "$registry_name" --image "azdq-runtime:${runtime_tag}" --query digest -o tsv)

azd env set AZDQ_GATEWAY_IMAGE "${registry_server}/azdq-gateway@${gateway_digest}"
azd env set AZDQ_RUNTIME_IMAGE "${registry_server}/azdq-runtime@${runtime_digest}"

# Stage 2: create and execute only the bootstrap job. Application replicas do
# not exist until the catalog and scoped PostgreSQL logins validate successfully.
azd env set AZDQ_DEPLOY_BOOTSTRAP true
azd env set AZDQ_DEPLOY_APPS false
azd provision --no-prompt

job_name=$(azd env get-value BOOTSTRAP_JOB_NAME)
execution_name=$(az containerapp job start --name "$job_name" --resource-group "$resource_group" --query name -o tsv)
for _ in {1..90}; do
  execution_status=$(az containerapp job execution show \
    --name "$job_name" \
    --resource-group "$resource_group" \
    --job-execution-name "$execution_name" \
    --query properties.status -o tsv)
  case "$execution_status" in
    Succeeded) break ;;
    Failed) echo "Bootstrap job failed: ${execution_name}" >&2; exit 1 ;;
  esac
  sleep 10
done
if [[ "${execution_status:-}" != "Succeeded" ]]; then
  echo "Bootstrap job did not succeed within 15 minutes: ${execution_name}" >&2
  exit 1
fi

# Stage 3: admit the immutable image digests to reader, writer, and gateway apps.
azd env set AZDQ_DEPLOY_APPS true
azd provision --no-prompt

echo "Deployment completed after successful bootstrap: ${execution_name}"
