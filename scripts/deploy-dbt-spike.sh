#!/usr/bin/env bash
set -euo pipefail

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to deploy the spike unless the worktree is clean." >&2
  exit 1
fi

subscription_id=$(azd env get-value AZURE_SUBSCRIPTION_ID)
resource_group=$(azd env get-value AZURE_RESOURCE_GROUP)
environment_name=$(azd env get-value AZURE_ENV_NAME)
registry_name=$(azd env get-value AZURE_CONTAINER_REGISTRY_NAME)
registry_server=$(azd env get-value AZURE_CONTAINER_REGISTRY_ENDPOINT)
aca_environment=$(azd env get-value AZURE_CONTAINER_APPS_ENVIRONMENT_NAME)
key_vault_name=$(azd env get-value AZURE_KEY_VAULT_NAME)
storage_account_name=$(azd env get-value AZURE_STORAGE_ACCOUNT)
postgres_server_fqdn=$(azd env get-value POSTGRES_SERVER_FQDN)

az account set --subscription "$subscription_id"

az group show --name "$resource_group" --output none
az acr show --name "$registry_name" --resource-group "$resource_group" --output none
az containerapp env show \
  --name "$aca_environment" \
  --resource-group "$resource_group" \
  --output none

consumption_quota=$(az containerapp env list-usages \
  --name "$aca_environment" \
  --resource-group "$resource_group" \
  --query "value[?name.value=='ManagedEnvironmentConsumptionCores'] | [0].{current:currentValue,limit:limit}" \
  --output json)
if ! jq -e '(.limit - .current) >= 0.5' <<<"$consumption_quota" >/dev/null; then
  echo "ACA environment lacks 0.5 available Consumption cores: ${consumption_quota}" >&2
  exit 1
fi

revision=$(git rev-parse --short=12 HEAD)
image_tag="spike-${revision}"
az acr build \
  --registry "$registry_name" \
  --platform linux/amd64 \
  --image "azdq-dbt-spike:${image_tag}" \
  --file docker/dbt-spike.Dockerfile \
  .

image_digest=$(az acr repository show \
  --name "$registry_name" \
  --image "azdq-dbt-spike:${image_tag}" \
  --query digest \
  --output tsv)
if [[ ! "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "ACR returned an invalid image digest: ${image_digest}" >&2
  exit 1
fi

location=$(az group show --name "$resource_group" --query location --output tsv)
container_apps_environment_id=$(az containerapp env show \
  --name "$aca_environment" \
  --resource-group "$resource_group" \
  --query id \
  --output tsv)
writer_identity=$(az identity list \
  --resource-group "$resource_group" \
  --query "[?starts_with(name, 'id-azdq-writer-')] | [0].{id:id,clientId:clientId}" \
  --output json)
writer_identity_id=$(jq -r .id <<<"$writer_identity")
writer_identity_client_id=$(jq -r .clientId <<<"$writer_identity")
postgres_writer_password_secret_uri="https://${key_vault_name}.vault.azure.net/secrets/postgres-writer-password"
data_path="az://${storage_account_name}.blob.core.windows.net/ducklake/data/"
dbt_spike_image="${registry_server}/azdq-dbt-spike@${image_digest}"

if [[ "$writer_identity_id" != /subscriptions/* || -z "$writer_identity_client_id" ]]; then
  echo "Could not resolve the existing writer managed identity." >&2
  exit 1
fi

deployment_name="dbt-spike-${revision}"
deployment_parameters=(
  "name=${environment_name}"
  "location=${location}"
  "containerAppsEnvironmentId=${container_apps_environment_id}"
  "registryServer=${registry_server}"
  "dbtSpikeImage=${dbt_spike_image}"
  "writerIdentityId=${writer_identity_id}"
  "writerIdentityClientId=${writer_identity_client_id}"
  "storageAccountName=${storage_account_name}"
  "dataPath=${data_path}"
  "postgresServerFqdn=${postgres_server_fqdn}"
  "postgresDatabaseName=ducklake_catalog"
  "postgresWriterPasswordSecretUri=${postgres_writer_password_secret_uri}"
)

# Deploy the standalone module so this contained spike cannot reconcile the
# existing apps, bootstrap job, PostgreSQL server, ACR, or ACA environment.
az deployment group what-if \
  --name "$deployment_name" \
  --resource-group "$resource_group" \
  --template-file infra/modules/dbt-spike.bicep \
  --parameters "${deployment_parameters[@]}" \
  --result-format ResourceIdOnly \
  --no-pretty-print
az deployment group create \
  --name "$deployment_name" \
  --resource-group "$resource_group" \
  --template-file infra/modules/dbt-spike.bicep \
  --parameters "${deployment_parameters[@]}" \
  --output none

job_name=caj-azdq-dbt-spike
execution_name=$(az containerapp job start \
  --name "$job_name" \
  --resource-group "$resource_group" \
  --query name \
  --output tsv)

execution_status=Unknown
for _ in {1..90}; do
  execution_status=$(az containerapp job execution show \
    --name "$job_name" \
    --resource-group "$resource_group" \
    --job-execution-name "$execution_name" \
    --query properties.status \
    --output tsv)
  case "$execution_status" in
    Succeeded) break ;;
    Failed)
      echo "dbt spike job failed: ${execution_name}" >&2
      exit 1
      ;;
  esac
  sleep 10
done

if [[ "$execution_status" != "Succeeded" ]]; then
  echo "dbt spike job did not succeed within 15 minutes: ${execution_name}" >&2
  exit 1
fi

echo "dbt spike succeeded: ${execution_name} (${dbt_spike_image})"
