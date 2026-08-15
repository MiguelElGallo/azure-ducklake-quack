FROM rust:1.97.1-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates ./crates
RUN cargo build --locked --release --package azdq-runtime --bins

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

# DuckDB's statically linked Azure SDK checks the Red Hat CA path even on
# Debian. Keep one source-of-truth bundle and expose that expected path.
FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 azdq \
    && mkdir -p /tmp/azdq /etc/pki/tls/certs \
    && ln -s /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt \
    && chown azdq:azdq /tmp/azdq
COPY --from=extensions --chown=10001:10001 /opt/azdq/.duckdb /home/azdq/.duckdb
COPY --from=extensions /usr/local/bin/duckdb /usr/local/bin/duckdb
COPY --from=build /src/target/release/azdq-runtime /usr/local/bin/azdq-runtime
COPY --from=build /src/target/release/bootstrap /usr/local/bin/azdq-bootstrap
USER 10001:10001
ENV HOME=/home/azdq
EXPOSE 8080 9494
ENTRYPOINT ["/usr/local/bin/azdq-runtime"]
