# Variables
ARG BUILDER=ubuntu:24.04
ARG IMAGE=${BUILDER}
ARG RUST_VERSION=${RUST_VERSION:-1.78.0}
ARG BUILD_HOME=/src
ARG MAKE_PARALLEL=${MAKE_PARALLEL:-4}
ARG NIMFLAGS="${NIMFLAGS:-"-d:disableMarchNative"}"
ARG APP_HOME=/codex
ARG NAT_IP_AUTO=${NAT_IP_AUTO:-false}

# Build
FROM ${BUILDER} AS builder
ARG RUST_VERSION
ARG BUILD_HOME
ARG MAKE_PARALLEL
ARG NIMFLAGS

RUN apt-get update && apt-get install -y git cmake curl make bash lcov build-essential
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs/ | sh -s -- --default-toolchain=${RUST_VERSION} -y

SHELL ["/bin/bash", "-c"]
ENV BASH_ENV="/etc/bash_env"
RUN echo "export PATH=$PATH:$HOME/.cargo/bin" >> $BASH_ENV

WORKDIR ${BUILD_HOME}
COPY . .
RUN make -j ${MAKE_PARALLEL} update
RUN make -j ${MAKE_PARALLEL}
RUN make -j ${MAKE_PARALLEL} cirdl

# Create
FROM ${IMAGE}
ARG BUILD_HOME
ARG APP_HOME
ARG NAT_IP_AUTO

WORKDIR ${APP_HOME}
COPY --from=builder ${BUILD_HOME}/build/* /usr/local/bin
COPY --from=builder ${BUILD_HOME}/openapi.yaml .
COPY --from=builder --chmod=0755 ${BUILD_HOME}/docker/docker-entrypoint.sh /
RUN apt-get update && apt-get install -y libgomp1 curl jq && rm -rf /var/lib/apt/lists/*
ENV NAT_IP_AUTO=${NAT_IP_AUTO}
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["codex"]
