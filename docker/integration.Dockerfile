# This multi-target image shares one Rust/DuckDB build across the three isolated
# integration-test containers. Production deployment still uses the smaller
# component Dockerfiles in this directory.
FROM rust:1.97.1-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates ./crates
RUN --mount=type=cache,id=azdq-cargo-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=azdq-integration-target,target=/src/target \
    cargo build --locked --release --workspace --bins \
    && mkdir /out \
    && cp /src/target/release/azdq /out/azdq \
    && cp /src/target/release/azdq-gateway /out/azdq-gateway \
    && cp /src/target/release/azdq-runtime /out/azdq-runtime \
    && cp /src/target/release/bootstrap /out/bootstrap

FROM debian:bookworm-slim AS extensions
ARG DUCKDB_VERSION=v1.5.5
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/azdq \
    && DEB_ARCH=$(dpkg --print-architecture) \
    && case "$DEB_ARCH" in amd64) DUCKDB_ARCH=amd64 ;; arm64) DUCKDB_ARCH=arm64 ;; *) exit 1 ;; esac \
    && curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-${DUCKDB_ARCH}.zip" -o /tmp/duckdb.zip \
    && unzip -q /tmp/duckdb.zip -d /usr/local/bin \
    && HOME=/opt/azdq /usr/local/bin/duckdb -c "INSTALL azure; INSTALL ducklake; INSTALL postgres; INSTALL quack;" \
    && rm /tmp/duckdb.zip

# The client needs Quack's post-1.5.5 EXTRA_HTTP_HEADERS support. Runtime
# containers stay on stable 1.5.5 while this reviewed preview pair is pinned.
FROM debian:bookworm-slim AS client-duckdb
ARG DUCKDB_PREVIEW_SERIES=v1.5-variegata
ARG DUCKDB_SOURCE_ID=11d6c02c0a
ARG QUACK_EXTENSION_VERSION=c154811
ARG DUCKDB_PREVIEW_AMD64_BINARY_SHA256=bada650d867d63b6f2db322c9d242cfd8290810b08165df538a11449f3015349
ARG DUCKDB_PREVIEW_ARM64_BINARY_SHA256=43a561a5173c964a3199c12e10587d954a16b8f4f0294bd782f3f374e8ae27f0
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/azdq \
    && DEB_ARCH=$(dpkg --print-architecture) \
    && case "$DEB_ARCH" in amd64) DUCKDB_ARCH=amd64; DUCKDB_BINARY_SHA256="$DUCKDB_PREVIEW_AMD64_BINARY_SHA256" ;; arm64) DUCKDB_ARCH=arm64; DUCKDB_BINARY_SHA256="$DUCKDB_PREVIEW_ARM64_BINARY_SHA256" ;; *) exit 1 ;; esac \
    && curl -fsSL "https://artifacts.duckdb.org/${DUCKDB_PREVIEW_SERIES}/duckdb-binaries-linux-${DUCKDB_ARCH}.zip" -o /tmp/duckdb-binaries.zip \
    && unzip -q /tmp/duckdb-binaries.zip "duckdb_cli-linux-${DUCKDB_ARCH}.zip" -d /tmp \
    && unzip -q "/tmp/duckdb_cli-linux-${DUCKDB_ARCH}.zip" -d /usr/local/bin \
    && echo "${DUCKDB_BINARY_SHA256}  /usr/local/bin/duckdb" | sha256sum --check --status \
    && /usr/local/bin/duckdb --version | grep -F "${DUCKDB_SOURCE_ID}" \
    && HOME=/opt/azdq /usr/local/bin/duckdb -csv -noheader -c "INSTALL quack; SELECT extension_version FROM duckdb_extensions() WHERE extension_name = 'quack';" | grep -Fx "${QUACK_EXTENSION_VERSION}" \
    && HOME=/opt/azdq /usr/local/bin/duckdb -batch -bail -c "LOAD quack; CREATE SECRET azdq_header_probe (TYPE quack, TOKEN 'header-probe-token', EXTRA_HTTP_HEADERS MAP {'Authorization': 'Bearer probe'});" >/dev/null \
    && rm -f /tmp/duckdb-binaries.zip "/tmp/duckdb_cli-linux-${DUCKDB_ARCH}.zip"

# Mirror the production image's Azure SDK certificate discovery path.
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 azdq \
    && mkdir -p /tmp/azdq /etc/pki/tls/certs \
    && ln -s /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
    && chown azdq:azdq /tmp/azdq
COPY --from=extensions --chown=10001:10001 /opt/azdq/.duckdb /home/azdq/.duckdb
COPY --from=extensions /usr/local/bin/duckdb /usr/local/bin/duckdb
COPY --from=build /out/azdq-runtime /usr/local/bin/azdq-runtime
COPY --from=build /out/bootstrap /usr/local/bin/azdq-bootstrap
USER 10001:10001
ENV HOME=/home/azdq
EXPOSE 8080 9494
ENTRYPOINT ["/usr/local/bin/azdq-runtime"]

FROM debian:bookworm-slim AS gateway
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 azdq
COPY --from=build /out/azdq-gateway /usr/local/bin/azdq-gateway
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/azdq-gateway"]

FROM debian:bookworm-slim AS client
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 azdq
COPY --from=client-duckdb --chown=10001:10001 /opt/azdq/.duckdb /home/azdq/.duckdb
COPY --from=client-duckdb /usr/local/bin/duckdb /usr/local/bin/duckdb
COPY --from=build /out/azdq /usr/local/bin/azdq
USER 10001:10001
ENV HOME=/home/azdq
ENTRYPOINT ["/usr/local/bin/azdq"]
