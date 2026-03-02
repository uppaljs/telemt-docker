# ============================================================
# Dockerfile — Telemt MTProxy (static binary, distroless)
# Multi-arch: amd64 / arm64
# ============================================================

# ----- configurable build args -----
ARG TELEMT_REPO=https://github.com/telemt/telemt.git
ARG TELEMT_REF=main
ARG RUST_VERSION=1.88

# ==========================
# Stage 1: Build (static via musl)
# ==========================
FROM rust:${RUST_VERSION}-slim-bookworm AS builder

ARG TELEMT_REPO
ARG TELEMT_REF
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        pkg-config \
        musl-tools \
    && rm -rf /var/lib/apt/lists/*

# Add the appropriate musl target
RUN case "${TARGETARCH}" in \
        amd64) MUSL_TARGET=x86_64-unknown-linux-musl  ;; \
        arm64) MUSL_TARGET=aarch64-unknown-linux-musl ;; \
        *)     echo "unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    rustup target add "${MUSL_TARGET}" && \
    echo "${MUSL_TARGET}" > /tmp/musl-target

WORKDIR /build

# Clone the upstream source at the pinned ref
RUN git clone --depth 1 --branch "${TELEMT_REF}" "${TELEMT_REPO}" .

# Cache dependency build with a dummy main
RUN mkdir -p src && \
    cp src/main.rs src/main.rs.bak 2>/dev/null || echo 'fn main() {}' > src/main.rs && \
    MUSL_TARGET=$(cat /tmp/musl-target) && \
    cargo build --release --target "${MUSL_TARGET}" 2>/dev/null || true && \
    mv src/main.rs.bak src/main.rs 2>/dev/null || true

# Build the real binary — fully static
RUN MUSL_TARGET=$(cat /tmp/musl-target) && \
    cargo build --release --target "${MUSL_TARGET}" && \
    cp "target/${MUSL_TARGET}/release/telemt" /telemt && \
    strip /telemt

# ==========================
# Stage 2: Distroless runtime
# ==========================
FROM gcr.io/distroless/static:nonroot

LABEL maintainer="uppaljs"
LABEL org.opencontainers.image.source="https://github.com/telemt/telemt"
LABEL org.opencontainers.image.description="Telemt — fast MTProto proxy (Rust + Tokio)"

COPY --from=builder --chown=nonroot:nonroot /telemt /usr/local/bin/telemt

EXPOSE 443/tcp
EXPOSE 9090/tcp

ENTRYPOINT ["telemt"]
CMD ["/etc/telemt.toml"]
