FROM python:3.12-slim-bookworm AS dbt-install

ARG TARGETARCH=amd64
ARG DBT_CORE_VERSION=2.0.0a5
ARG DBC_VERSION=0.3.0
ARG DUCKDB_VERSION=1.5.5

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && case "$TARGETARCH" in \
         amd64) \
           DBT_PLATFORM=manylinux_2_28_x86_64; \
           DBT_SHA256=a8e3f960d6070cde00cd8a2bb85dd3ce9b8f2e755de6eab42ea469e1ab778629; \
           DBC_FILENAME=dbc-0.3.0-py3-none-manylinux_2_12_x86_64.manylinux2010_x86_64.whl; \
           DBC_SHA256=57c358cd9dec0b4f2b168ec60c213b059a0aeeeecdb6c4e65f5a489f287e2316; \
           DBC_URL=https://files.pythonhosted.org/packages/22/49/d79b26b9c7872cb3553175119b10a53e4b59b27335817f895d98b425fbb3/dbc-0.3.0-py3-none-manylinux_2_12_x86_64.manylinux2010_x86_64.whl \
           ;; \
         arm64) \
           DBT_PLATFORM=manylinux_2_28_aarch64; \
           DBT_SHA256=2a5a99c8dc9072374318a6b7ac42a760d3e5f1b01cc97ffb203e144d9b03af4f; \
           DBC_FILENAME=dbc-0.3.0-py3-none-manylinux_2_17_aarch64.manylinux2014_aarch64.whl; \
           DBC_SHA256=914e1c7da8ee31b662ce5925d67c2f8a7f0d2f9e4228f8458d3a6e331e53dd0f; \
           DBC_URL=https://files.pythonhosted.org/packages/99/33/c720b150c2c4276fba528a2760059335d9fa0651340282bf005cf661e94d/dbc-0.3.0-py3-none-manylinux_2_17_aarch64.manylinux2014_aarch64.whl \
           ;; \
         *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && DBT_FILENAME="dbt_core-${DBT_CORE_VERSION}-py3-none-${DBT_PLATFORM}.whl" \
    && curl -fsSL \
         "https://github.com/dbt-labs/dbt-core/releases/download/v2.0.0-alpha.5/${DBT_FILENAME}" \
         -o "/tmp/${DBT_FILENAME}" \
    && echo "${DBT_SHA256}  /tmp/${DBT_FILENAME}" | sha256sum -c - \
    && curl -fsSL "$DBC_URL" -o "/tmp/${DBC_FILENAME}" \
    && echo "${DBC_SHA256}  /tmp/${DBC_FILENAME}" | sha256sum -c - \
    && python -m pip install --no-cache-dir "/tmp/${DBT_FILENAME}" "/tmp/${DBC_FILENAME}" \
    && dbc install --level system "duckdb=${DUCKDB_VERSION}" \
    && dbc list --json \
    && dbt --version \
    && rm -f "/tmp/${DBT_FILENAME}" "/tmp/${DBC_FILENAME}"

FROM debian:bookworm-slim AS extensions

ARG TARGETARCH=amd64
ARG DUCKDB_VERSION=1.5.5

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && case "$TARGETARCH" in \
         amd64) DUCKDB_ARCH=amd64; DUCKDB_SHA256=08c0ca117111fcede14239d0093792352befdc174218c344d232c13279643d05 ;; \
         arm64) DUCKDB_ARCH=arm64; DUCKDB_SHA256=02163197027a42149147364d31fa67cac82108517a4be43304a1cc226eaef07a ;; \
         *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL \
         "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${DUCKDB_ARCH}.zip" \
         -o /tmp/duckdb.zip \
    && echo "${DUCKDB_SHA256}  /tmp/duckdb.zip" | sha256sum -c - \
    && unzip -q /tmp/duckdb.zip -d /usr/local/bin \
    && mkdir -p /opt/azdq \
    && HOME=/opt/azdq duckdb -c "INSTALL azure; INSTALL ducklake; INSTALL postgres;" \
    && rm -f /tmp/duckdb.zip

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 azdq \
    && mkdir -p /opt/azdq/dbt-spike /tmp/azdq-dbt-spike /etc/pki/tls/certs \
    && ln -s /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
    && chown -R azdq:azdq /opt/azdq /tmp/azdq-dbt-spike

COPY --from=dbt-install /usr/local/bin/dbt /usr/local/bin/dbt
COPY --from=dbt-install /etc/adbc /etc/adbc
COPY --from=extensions --chown=10001:10001 /opt/azdq/.duckdb /home/azdq/.duckdb
COPY --chown=10001:10001 spikes/dbt /opt/azdq/dbt-spike

RUN chmod 0555 /opt/azdq/dbt-spike/run.sh \
    && find /opt/azdq/dbt-spike -type f ! -name run.sh -exec chmod 0444 {} + \
    && read -r dbt_user_id < /proc/sys/kernel/random/uuid \
    && printf 'id: %s\n' "$dbt_user_id" > /opt/azdq/dbt-spike/.user.yml \
    && touch /opt/azdq/dbt-spike/.gitignore \
    && chown azdq:azdq /opt/azdq/dbt-spike/.user.yml \
    && chown azdq:azdq /opt/azdq/dbt-spike/.gitignore \
    && chmod 0400 /opt/azdq/dbt-spike/.user.yml \
    && chmod 0644 /opt/azdq/dbt-spike/.gitignore

USER 10001:10001
ENV HOME=/home/azdq \
    DBT_PROJECT_DIR=/opt/azdq/dbt-spike \
    DBT_LOG_PATH=/tmp/azdq-dbt-spike/logs \
    DBT_TARGET_PATH=/tmp/azdq-dbt-spike/target \
    DBT_TARGET=writer \
    DUCKLAKE_METADATA_PATH=postgres: \
    DUCKLAKE_METADATA_SCHEMA=public \
    PGPORT=5432 \
    PGSSLMODE=require \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_INFO=/etc/ssl/certs/ca-certificates.crt

WORKDIR /opt/azdq/dbt-spike
ENTRYPOINT ["/opt/azdq/dbt-spike/run.sh"]
