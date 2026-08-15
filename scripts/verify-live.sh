#!/usr/bin/env bash
set -euo pipefail

resource_group=$(azd env get-value AZURE_RESOURCE_GROUP)
gateway_url=$(azd env get-value GATEWAY_URL)
tenant_id=$(azd env get-value AZDQ_TENANT_ID)
client_id=$(azd env get-value AZDQ_NATIVE_CLIENT_ID)
scope=$(azd env get-value AZDQ_API_SCOPE)
job_name=$(azd env get-value BOOTSTRAP_JOB_NAME)
duckdb_path=${DUCKDB_PATH:-duckdb}

# Stable 1.5.5 rejects EXTRA_HTTP_HEADERS. Feature-probe the actual executable
# before starting an interactive Entra flow so failures are immediate and clear.
if ! "$duckdb_path" -no-init -batch -bail -c \
  "LOAD quack; CREATE SECRET azdq_header_probe (TYPE quack, TOKEN 'header-probe-token', EXTRA_HTTP_HEADERS MAP {'Authorization': 'Bearer probe'});" \
  >/dev/null 2>&1; then
  echo "DUCKDB_PATH must point to a DuckDB/Quack pair with EXTRA_HTTP_HEADERS support; see docs/compatibility.md." >&2
  exit 1
fi

curl --fail --silent --show-error "${gateway_url}/healthz" -o /dev/null
unauthenticated_status=$(curl --silent --output /dev/null --write-out '%{http_code}' "${gateway_url}/session")
if [[ "$unauthenticated_status" != "401" ]]; then
  echo "Expected unauthenticated /session to return 401, got ${unauthenticated_status}." >&2
  exit 1
fi

bootstrap_status=$(az containerapp job execution list \
  --name "$job_name" \
  --resource-group "$resource_group" \
  --query '[0].properties.status' -o tsv)
if [[ "$bootstrap_status" != "Succeeded" ]]; then
  echo "Latest bootstrap execution is not successful: ${bootstrap_status}" >&2
  exit 1
fi

if [[ -z "${AZDQ_ACCESS_TOKEN:-}" ]]; then
  authority="https://login.microsoftonline.com/${tenant_id}/oauth2/v2.0"
  device_json=$(curl --fail --silent --show-error \
    --data-urlencode "client_id=${client_id}" \
    --data-urlencode "scope=${scope}" \
    "${authority}/devicecode")
  jq -r .message <<<"$device_json"
  device_code=$(jq -r .device_code <<<"$device_json")
  interval=$(jq -r '.interval // 5' <<<"$device_json")
  expires_in=$(jq -r .expires_in <<<"$device_json")
  deadline=$((SECONDS + expires_in))
  while (( SECONDS < deadline )); do
    sleep "$interval"
    token_json=$(curl --silent --show-error \
      --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:device_code' \
      --data-urlencode "client_id=${client_id}" \
      --data-urlencode "device_code=${device_code}" \
      "${authority}/token")
    token_error=$(jq -r '.error // empty' <<<"$token_json")
    if [[ -z "$token_error" ]]; then
      export AZDQ_ACCESS_TOKEN
      AZDQ_ACCESS_TOKEN=$(jq -r .access_token <<<"$token_json")
      break
    fi
    if [[ "$token_error" == "slow_down" ]]; then
      interval=$((interval + 5))
    elif [[ "$token_error" != "authorization_pending" ]]; then
      echo "Device authentication failed: $(jq -r '.error_description // .error' <<<"$token_json")" >&2
      exit 1
    fi
  done
fi
if [[ -z "${AZDQ_ACCESS_TOKEN:-}" ]]; then
  echo "Device authentication expired." >&2
  exit 1
fi

export AZDQ_TENANT_ID="$tenant_id"
export AZDQ_CLIENT_ID="$client_id"
export AZDQ_SCOPE="$scope"
export AZDQ_ENDPOINT="$gateway_url"

cargo run --locked --release --package azdq-client --bin azdq -- \
  sql --role writer --query 'CREATE TABLE IF NOT EXISTS analytics.release_smoke(id INTEGER, note VARCHAR)'
cargo run --locked --release --package azdq-client --bin azdq -- \
  sql --role writer --query "INSERT INTO analytics.release_smoke VALUES (1, 'committed')"
cargo run --locked --release --package azdq-client --bin azdq -- \
  sql --query 'SELECT count(*) AS committed_rows FROM analytics.release_smoke'

if cargo run --locked --release --package azdq-client --bin azdq -- \
  sql --query "INSERT INTO analytics.release_smoke VALUES (2, 'reader-must-fail')"; then
  echo "Reader write unexpectedly succeeded." >&2
  exit 1
fi

echo "Authenticated default-reader, writer commit, reconnect, and reader-denial checks passed."
