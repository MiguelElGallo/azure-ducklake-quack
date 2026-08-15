#!/usr/bin/env bash
set -euo pipefail

# Creates only project-scoped Entra objects. If an object with the intended display
# name already exists but was not recorded in the azd environment, the script stops.

environment_name=${AZURE_ENV_NAME:-azdqdev}
tenant_id=$(az account show --query tenantId -o tsv)
current_user_id=$(az ad signed-in-user show --query id -o tsv)
api_name="Azure DuckLake Quack API (${environment_name})"
native_name="Azure DuckLake Quack CLI (${environment_name})"
reader_name="Azure DuckLake Quack Readers (${environment_name})"
writer_name="Azure DuckLake Quack Writers (${environment_name})"
ownership_marker="azure-ducklake-quack:${environment_name}"
environment_values=$(azd env get-values --output json)

get_env() {
  jq -r --arg name "$1" '.[$name] // empty' <<<"$environment_values"
}

ensure_absent() {
  local kind=$1
  local filter=$2
  local recorded=$3
  local found
  if [[ -n "$recorded" ]]; then
    return
  fi
  case "$kind" in
    app) found=$(az ad app list --filter "displayName eq '$filter'" --query 'length(@)' -o tsv) ;;
    group) found=$(az ad group list --filter "displayName eq '$filter'" --query 'length(@)' -o tsv) ;;
  esac
  if [[ "$found" != "0" ]]; then
    echo "Refusing to modify pre-existing Entra $kind named: $filter" >&2
    exit 1
  fi
}

validate_recorded() {
  local kind=$1
  local id=$2
  local expected_name=$3
  local object
  if [[ -z "$id" ]]; then
    return
  fi
  case "$kind" in
    app)
      object=$(az ad app show --id "$id" -o json)
      if ! jq -e --arg name "$expected_name" --arg marker "$ownership_marker" \
        '.displayName == $name and ((.tags // []) | index($marker) != null)' \
        <<<"$object" >/dev/null; then
        echo "Recorded Entra app is not owned by this project environment: ${id}" >&2
        exit 1
      fi
      ;;
    group)
      object=$(az ad group show --group "$id" -o json)
      if ! jq -e --arg name "$expected_name" --arg marker "$ownership_marker" \
        '.displayName == $name and .description == $marker' <<<"$object" >/dev/null; then
        echo "Recorded Entra group is not owned by this project environment: ${id}" >&2
        exit 1
      fi
      ;;
  esac
}

reader_group_id=$(get_env AZDQ_READER_GROUP_ID)
writer_group_id=$(get_env AZDQ_WRITER_GROUP_ID)
api_client_id=$(get_env AZDQ_API_CLIENT_ID)
native_client_id=$(get_env AZDQ_NATIVE_CLIENT_ID)

validate_recorded group "$reader_group_id" "$reader_name"
validate_recorded group "$writer_group_id" "$writer_name"
validate_recorded app "$api_client_id" "$api_name"
validate_recorded app "$native_client_id" "$native_name"

ensure_absent group "$reader_name" "$reader_group_id"
ensure_absent group "$writer_name" "$writer_group_id"
ensure_absent app "$api_name" "$api_client_id"
ensure_absent app "$native_name" "$native_client_id"

if [[ -z "$reader_group_id" ]]; then
  reader_group_id=$(az ad group create \
    --display-name "$reader_name" \
    --mail-nickname "azdq-readers-${environment_name}" \
    --description "$ownership_marker" \
    --query id -o tsv)
  az ad group member add --group "$reader_group_id" --member-id "$current_user_id"
fi

if [[ -z "$writer_group_id" ]]; then
  writer_group_id=$(az ad group create \
    --display-name "$writer_name" \
    --mail-nickname "azdq-writers-${environment_name}" \
    --description "$ownership_marker" \
    --query id -o tsv)
  az ad group member add --group "$writer_group_id" --member-id "$current_user_id"
fi

scope_id=$(get_env AZDQ_API_SCOPE_ID)
if [[ -z "$api_client_id" ]]; then
  api_json=$(az ad app create --display-name "$api_name" --sign-in-audience AzureADMyOrg -o json)
  api_object_id=$(jq -r .id <<<"$api_json")
  api_client_id=$(jq -r .appId <<<"$api_json")
  scope_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  api_body=$(jq -n \
    --arg uri "api://${api_client_id}" \
    --arg scope "$scope_id" \
    --arg marker "$ownership_marker" \
    '{tags:[$marker],identifierUris:[$uri],groupMembershipClaims:"SecurityGroup",api:{requestedAccessTokenVersion:2,oauth2PermissionScopes:[{adminConsentDescription:"Access Azure DuckLake Quack",adminConsentDisplayName:"Access Azure DuckLake Quack",id:$scope,isEnabled:true,type:"User",userConsentDescription:"Access Azure DuckLake Quack",userConsentDisplayName:"Access Azure DuckLake Quack",value:"access_as_user"}]}}')
  az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/${api_object_id}" --body "$api_body" >/dev/null
  az ad sp create --id "$api_client_id" >/dev/null
else
  api_object_id=$(az ad app show --id "$api_client_id" --query id -o tsv)
fi

if [[ -z "$native_client_id" ]]; then
  native_json=$(az ad app create --display-name "$native_name" --sign-in-audience AzureADMyOrg --is-fallback-public-client true -o json)
  native_object_id=$(jq -r .id <<<"$native_json")
  native_client_id=$(jq -r .appId <<<"$native_json")
  native_body=$(jq -n \
    --arg api "$api_client_id" \
    --arg scope "$scope_id" \
    --arg marker "$ownership_marker" \
    '{tags:[$marker],isFallbackPublicClient:true,publicClient:{redirectUris:["http://localhost"]},requiredResourceAccess:[{resourceAppId:$api,resourceAccess:[{id:$scope,type:"Scope"}]}]}')
  az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/${native_object_id}" --body "$native_body" >/dev/null
  az ad sp create --id "$native_client_id" >/dev/null

  preauth_body=$(jq -n --arg app "$native_client_id" --arg scope "$scope_id" \
    '{api:{requestedAccessTokenVersion:2,oauth2PermissionScopes:[{adminConsentDescription:"Access Azure DuckLake Quack",adminConsentDisplayName:"Access Azure DuckLake Quack",id:$scope,isEnabled:true,type:"User",userConsentDescription:"Access Azure DuckLake Quack",userConsentDisplayName:"Access Azure DuckLake Quack",value:"access_as_user"}],preAuthorizedApplications:[{appId:$app,delegatedPermissionIds:[$scope]}]}}')
  az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/${api_object_id}" --body "$preauth_body" >/dev/null
fi

# A new credential is created only once for this azd environment. Its value remains
# in the gitignored azd environment store and is copied to Key Vault by Bicep.
api_client_secret=$(get_env AZDQ_API_CLIENT_SECRET)
if [[ -z "$api_client_secret" ]]; then
  api_client_secret=$(az ad app credential reset \
    --id "$api_client_id" --append \
    --display-name "azdq-${environment_name}" \
    --years 1 --query password -o tsv)
fi

azd env set AZDQ_READER_GROUP_ID "$reader_group_id"
azd env set AZDQ_WRITER_GROUP_ID "$writer_group_id"
azd env set AZDQ_API_CLIENT_ID "$api_client_id"
azd env set AZDQ_NATIVE_CLIENT_ID "$native_client_id"
azd env set AZDQ_API_SCOPE_ID "$scope_id"
azd env set AZDQ_API_SCOPE "api://${api_client_id}/access_as_user offline_access openid"
azd env set AZDQ_API_CLIENT_SECRET "$api_client_secret"
azd env set AZDQ_TENANT_ID "$tenant_id"

echo "Created project-scoped Entra apps and groups for ${environment_name}."
