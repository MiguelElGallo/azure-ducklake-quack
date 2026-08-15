FROM rust:1.97.1-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates ./crates
RUN cargo build --locked --release --package azdq-client --bin azdq

FROM debian:bookworm-slim AS duckdb
# Quack custom headers landed after DuckDB 1.5.5. Pin the reviewed official
# v1.5 preview artifact by checksum and fail closed when the nightly moves.
ARG DUCKDB_PREVIEW_SERIES=v1.5-variegata
ARG DUCKDB_SOURCE_ID=11d6c02c0a
ARG QUACK_EXTENSION_VERSION=c154811
ARG DUCKDB_PREVIEW_AMD64_SHA256=dc05418056fd7ac837e125aabe07be8e711485be2ef14936a3959b3adbad351c
ARG DUCKDB_PREVIEW_ARM64_SHA256=bafc6649a63754bb9e1c7a9cb4ee7146bd24f8879bad57121e98f5eb452df698
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/azdq \
    && DEB_ARCH=$(dpkg --print-architecture) \
    && case "$DEB_ARCH" in amd64) DUCKDB_ARCH=amd64; DUCKDB_SHA256="$DUCKDB_PREVIEW_AMD64_SHA256" ;; arm64) DUCKDB_ARCH=arm64; DUCKDB_SHA256="$DUCKDB_PREVIEW_ARM64_SHA256" ;; *) exit 1 ;; esac \
    && curl -fsSL "https://artifacts.duckdb.org/${DUCKDB_PREVIEW_SERIES}/duckdb-binaries-linux-${DUCKDB_ARCH}.zip" -o /tmp/duckdb-binaries.zip \
    && echo "${DUCKDB_SHA256}  /tmp/duckdb-binaries.zip" | sha256sum --check --status \
    && unzip -q /tmp/duckdb-binaries.zip "duckdb_cli-linux-${DUCKDB_ARCH}.zip" -d /tmp \
    && unzip -q "/tmp/duckdb_cli-linux-${DUCKDB_ARCH}.zip" -d /usr/local/bin \
    && /usr/local/bin/duckdb --version | grep -F "${DUCKDB_SOURCE_ID}" \
    && HOME=/opt/azdq /usr/local/bin/duckdb -csv -noheader -c "INSTALL quack; SELECT extension_version FROM duckdb_extensions() WHERE extension_name = 'quack';" | grep -Fx "${QUACK_EXTENSION_VERSION}" \
    && HOME=/opt/azdq /usr/local/bin/duckdb -batch -bail -c "LOAD quack; CREATE SECRET azdq_header_probe (TYPE quack, TOKEN 'header-probe-token', EXTRA_HTTP_HEADERS MAP {'Authorization': 'Bearer probe'});" >/dev/null \
    && rm -f /tmp/duckdb-binaries.zip "/tmp/duckdb_cli-linux-${DUCKDB_ARCH}.zip"

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 azdq
COPY --from=duckdb --chown=10001:10001 /opt/azdq/.duckdb /home/azdq/.duckdb
COPY --from=duckdb /usr/local/bin/duckdb /usr/local/bin/duckdb
COPY --from=build /src/target/release/azdq /usr/local/bin/azdq
USER 10001:10001
ENV HOME=/home/azdq
ENTRYPOINT ["/usr/local/bin/azdq"]
