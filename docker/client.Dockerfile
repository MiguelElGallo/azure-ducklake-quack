FROM rust:1.97.1-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates ./crates
RUN cargo build --locked --release --package azdq-client --bin azdq

FROM debian:bookworm-slim AS duckdb
ARG TARGETARCH
ARG DUCKDB_VERSION=v1.5.5
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/azdq \
    && case "$TARGETARCH" in amd64) DUCKDB_ARCH=amd64 ;; arm64) DUCKDB_ARCH=arm64 ;; *) exit 1 ;; esac \
    && curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-${DUCKDB_ARCH}.zip" -o /tmp/duckdb.zip \
    && unzip -q /tmp/duckdb.zip -d /usr/local/bin \
    && HOME=/opt/azdq /usr/local/bin/duckdb -c "INSTALL quack;" \
    && rm /tmp/duckdb.zip

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
