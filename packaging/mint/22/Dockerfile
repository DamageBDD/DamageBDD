# Dockerfile.mint22-builder
# Base: Mint 22 (Ubuntu 24.04 compatible). Swap to linuxmintd/mint22-amd64 if available.
#FROM ubuntu:24.04
FROM linuxmintd/mint22-amd64

ARG DEBIAN_FRONTEND=noninteractive
ARG REBAR3_URL=https://s3.amazonaws.com/rebar3/rebar3

# Tools + build deps (incl. libsodium), Ruby/fpm, and useful packaging bits.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf m4 \
      libncurses-dev libssl-dev xsltproc fop unixodbc-dev \
      ca-certificates curl git wget xz-utils pkg-config \
      libsodium23 libsodium-dev \
      ruby ruby-dev rubygems \
      rpm dpkg-dev gnupg \
    && gem install --no-document fpm \
    && rm -rf /var/lib/apt/lists/*

# kerl (OTP builder)
RUN curl -fsSL https://raw.githubusercontent.com/kerl/kerl/master/kerl \
      -o /usr/local/bin/kerl \
 && chmod +x /usr/local/bin/kerl

# Build & install Erlang/OTP 28 with kerl
ENV KERL_BUILD_BACKEND=tarball \
    KERL_DOWNLOAD_DIR=/root/.kerl/archives \
    KERL_BUILD_DIR=/root/.kerl/builds \
    KERL_CONFIGURE_OPTIONS="--disable-debug --without-javac"
ARG OTP_VERSION=28.1
RUN kerl update releases \
 && kerl build ${OTP_VERSION} ${OTP_VERSION} \
 && mkdir -p /opt/erlang/${OTP_VERSION} \
 && kerl install ${OTP_VERSION} /opt/erlang/${OTP_VERSION}

# rebar3
RUN curl -fsSL ${REBAR3_URL} -o /usr/local/bin/rebar3 \
 && chmod +x /usr/local/bin/rebar3

# PATH for OTP 28
ENV PATH="/opt/erlang/${OTP_VERSION}/bin:/usr/local/bin:${PATH}"

# Working dir where you'll mount your project
WORKDIR /opt/workspace

RUN ls
RUN git clone https://github.com/DamageBDD/DamageBDD.git .

# Helpful default cmd (does nothing by itself).
CMD ["/bin/bash"]

