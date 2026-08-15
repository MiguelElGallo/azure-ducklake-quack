FROM rust:1.97.1-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates ./crates
RUN cargo build --locked --release --package azdq-gateway

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 azdq
COPY --from=build /src/target/release/azdq-gateway /usr/local/bin/azdq-gateway
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/azdq-gateway"]

