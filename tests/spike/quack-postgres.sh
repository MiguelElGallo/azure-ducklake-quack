#!/usr/bin/env bash
set -euo pipefail

for command in docker jq; do
  if ! command -v "$command" >/dev/null; then
    echo "Required command is missing: ${command}" >&2
    exit 1
  fi
done

run_id=$$
prefix="azdq-spike-${run_id}"
network="${prefix}"
data_volume="${prefix}-data"
postgres="${prefix}-postgres"
reader="${prefix}-reader"
writer="${prefix}-writer"
gateway="${prefix}-gateway"
runtime_image="${prefix}-runtime"
gateway_image="${prefix}-gateway"
client_image="${prefix}-client"

cleanup() {
  status=$?
  if (( status != 0 )); then
    for container in "$gateway" "$reader" "$writer" "$postgres"; do
      echo "--- ${container} logs ---" >&2
      docker logs "$container" >&2 2>/dev/null || true
    done
  fi
  docker container rm --force "$gateway" "$reader" "$writer" "$postgres" >/dev/null 2>&1 || true
  docker volume rm "$data_volume" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm "$runtime_image" "$gateway_image" "$client_image" >/dev/null 2>&1 || true
  return "$status"
}
trap cleanup EXIT INT TERM

docker network create "$network" >/dev/null
docker volume create "$data_volume" >/dev/null
docker run --rm --volume "${data_volume}:/data" alpine:3.22 chown 10001:10001 /data

docker build --target runtime --tag "$runtime_image" --file docker/integration.Dockerfile .
docker build --target gateway --tag "$gateway_image" --file docker/integration.Dockerfile .
docker build --target client --tag "$client_image" --file docker/integration.Dockerfile .

admin_password='admin-password-0123456789'
reader_password='reader-password-0123456789'
writer_password='writer-password-0123456789'
reader_token='reader-quack-token-0123456789'
writer_token='writer-quack-token-0123456789'

docker run --detach --name "$postgres" --network "$network" --network-alias postgres \
  --env POSTGRES_DB=ducklake_catalog \
  --env POSTGRES_USER=azdq_admin \
  --env "POSTGRES_PASSWORD=${admin_password}" \
  postgres:17-bookworm >/dev/null

for _ in {1..60}; do
  if docker exec "$postgres" pg_isready --username azdq_admin --dbname ducklake_catalog >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
docker exec "$postgres" pg_isready --username azdq_admin --dbname ducklake_catalog >/dev/null

docker run --rm --network "$network" --volume "${data_volume}:/data" \
  --entrypoint /usr/local/bin/azdq-bootstrap \
  --env AZDQ_STORAGE_PROVIDER=local \
  --env POSTGRES_HOST=postgres \
  --env POSTGRES_DATABASE=ducklake_catalog \
  --env POSTGRES_ADMIN_USER=azdq_admin \
  --env "POSTGRES_ADMIN_PASSWORD=${admin_password}" \
  --env POSTGRES_SSLMODE=disable \
  --env DUCKLAKE_METADATA_SCHEMA=public \
  --env DUCKLAKE_DATA_PATH=/data/ \
  --env POSTGRES_READER_USER=azdq_reader \
  --env "POSTGRES_READER_PASSWORD=${reader_password}" \
  --env POSTGRES_WRITER_USER=azdq_writer \
  --env "POSTGRES_WRITER_PASSWORD=${writer_password}" \
  "$runtime_image"

docker run --detach --name "$reader" --network "$network" --network-alias reader \
  --volume "${data_volume}:/data:ro" \
  --env AZDQ_ROLE=reader \
  --env AZDQ_STORAGE_PROVIDER=local \
  --env POSTGRES_HOST=postgres \
  --env POSTGRES_DATABASE=ducklake_catalog \
  --env POSTGRES_USER=azdq_reader \
  --env "POSTGRES_PASSWORD=${reader_password}" \
  --env POSTGRES_SSLMODE=disable \
  --env DUCKLAKE_METADATA_SCHEMA=public \
  --env DUCKLAKE_DATA_PATH=/data/ \
  --env "QUACK_TOKEN=${reader_token}" \
  "$runtime_image" >/dev/null

docker run --detach --name "$writer" --network "$network" --network-alias writer \
  --volume "${data_volume}:/data" \
  --env AZDQ_ROLE=writer \
  --env AZDQ_STORAGE_PROVIDER=local \
  --env POSTGRES_HOST=postgres \
  --env POSTGRES_DATABASE=ducklake_catalog \
  --env POSTGRES_USER=azdq_writer \
  --env "POSTGRES_PASSWORD=${writer_password}" \
  --env POSTGRES_SSLMODE=disable \
  --env DUCKLAKE_METADATA_SCHEMA=public \
  --env DUCKLAKE_DATA_PATH=/data/ \
  --env "QUACK_TOKEN=${writer_token}" \
  "$runtime_image" >/dev/null

reader_group='00000000-0000-0000-0000-000000000001'
writer_group='00000000-0000-0000-0000-000000000002'
docker run --detach --name "$gateway" --network "$network" --network-alias gateway \
  --env PUBLIC_QUACK_URI=quack:gateway:8080 \
  --env READER_BACKEND_URL=http://reader:9494 \
  --env WRITER_BACKEND_URL=http://writer:9494 \
  --env "ENTRA_READER_GROUP_ID=${reader_group}" \
  --env "ENTRA_WRITER_GROUP_ID=${writer_group}" \
  --env "READER_QUACK_TOKEN=${reader_token}" \
  --env "WRITER_QUACK_TOKEN=${writer_token}" \
  "$gateway_image" >/dev/null

for service in reader:8080 writer:8080 gateway:8080; do
  for _ in {1..90}; do
    if docker run --rm --network "$network" --entrypoint /usr/bin/wget alpine:3.22 \
      -q -O /dev/null "http://${service}/readyz"; then
      break
    fi
    sleep 1
  done
  docker run --rm --network "$network" --entrypoint /usr/bin/wget alpine:3.22 \
    -q -O /dev/null "http://${service}/readyz"
done

# Prove the backend protocol itself works before exercising the authorization proxy.
docker run --rm --network "$network" --entrypoint /usr/local/bin/duckdb "$client_image" -c \
  "LOAD quack; FROM quack_query('quack:writer:9494', 'SELECT 1', token => '${writer_token}', disable_ssl => true);"

principal_json=$(jq -cn --arg reader "$reader_group" --arg writer "$writer_group" \
  '{claims:[{typ:"groups",val:$reader},{typ:"groups",val:$writer}]}')
principal=$(printf '%s' "$principal_json" | base64 | tr -d '\n')

run_client() {
  docker run --rm --network "$network" \
    --env AZDQ_ACCESS_TOKEN=local-integration-token \
    --env "AZDQ_TEST_CLIENT_PRINCIPAL=${principal}" \
    --env AZDQ_TEST_CLIENT_PRINCIPAL_ID=local-subject \
    --env AZDQ_TEST_DISABLE_SSL=true \
    "$client_image" sql \
      --tenant-id local-tenant \
      --client-id local-client \
      --scope local-scope \
      --endpoint http://gateway:8080 \
      "$@"
}

run_client --role writer --query \
  'CREATE TABLE IF NOT EXISTS analytics.orders(id INTEGER, note VARCHAR)'
run_client --role writer --query \
  "INSERT INTO analytics.orders VALUES (1, 'committed')"
run_client --query \
  'SELECT count(*) AS committed_rows FROM analytics.orders'

if run_client --query "INSERT INTO analytics.orders VALUES (2, 'reader-must-fail')"; then
  echo "Reader write unexpectedly succeeded." >&2
  exit 1
fi

run_client --role writer --query \
  "INSERT INTO analytics.orders VALUES (3, 'reconnected')"
run_client --query \
  'SELECT count(*) AS reconnected_rows FROM analytics.orders'

echo "Quack/PostgreSQL/DuckLake gateway integration passed."
