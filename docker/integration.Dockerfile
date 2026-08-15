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
# Default for classic Docker builders; multi-platform callers may override it.
ARG TARGETARCH=amd64
ARG DUCKDB_VERSION=v1.5.5
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /opt/azdq \
    && case "$TARGETARCH" in amd64) DUCKDB_ARCH=amd64 ;; arm64) DUCKDB_ARCH=arm64 ;; *) exit 1 ;; esac \
    && curl -fsSL "https://github.com/duckdb/duckdb/releases/download/${DUCKDB_VERSION}/duckdb_cli-linux-${DUCKDB_ARCH}.zip" -o /tmp/duckdb.zip \
    && unzip -q /tmp/duckdb.zip -d /usr/local/bin \
    && HOME=/opt/azdq /usr/local/bin/duckdb -c "INSTALL azure; INSTALL ducklake; INSTALL postgres; INSTALL quack;" \
    && rm /tmp/duckdb.zip

FROM debian:bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 azdq \
    && mkdir -p /tmp/azdq \
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
COPY --from=extensions --chown=10001:10001 /opt/azdq/.duckdb /home/azdq/.duckdb
COPY --from=extensions /usr/local/bin/duckdb /usr/local/bin/duckdb
COPY --from=build /out/azdq /usr/local/bin/azdq
USER 10001:10001
ENV HOME=/home/azdq
ENTRYPOINT ["/usr/local/bin/azdq"]
