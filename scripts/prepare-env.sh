#!/usr/bin/env bash
set -euo pipefail

subscription_id=${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID explicitly}
environment_name=${AZURE_ENV_NAME:-azdqdev}
location=${AZURE_LOCATION:-swedencentral}

az account set --subscription "$subscription_id"
if ! azd env list --output json | jq -e --arg name "$environment_name" '.[] | select(.Name == $name)' >/dev/null; then
  azd env new "$environment_name" --location "$location" --subscription "$subscription_id" --no-prompt
else
  azd env select "$environment_name"
fi

azd env set AZURE_SUBSCRIPTION_ID "$subscription_id"
azd env set AZURE_LOCATION "$location"
azd env set AZDQ_DEPLOY_BOOTSTRAP false
azd env set AZDQ_DEPLOY_APPS false

for variable in AZDQ_POSTGRES_ADMIN_PASSWORD AZDQ_POSTGRES_READER_PASSWORD AZDQ_POSTGRES_WRITER_PASSWORD AZDQ_READER_QUACK_TOKEN AZDQ_WRITER_QUACK_TOKEN; do
  if ! azd env get-value "$variable" >/dev/null 2>&1; then
    azd env set "$variable" "$(openssl rand -hex 32)"
  fi
done

./scripts/entra-bootstrap.sh
