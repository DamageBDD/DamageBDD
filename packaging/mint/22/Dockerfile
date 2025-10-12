# Dockerfile.mint22-builder
FROM linuxmintd/mint22-amd64

ARG DEBIAN_FRONTEND=noninteractive
ARG REBAR3_URL=https://s3.amazonaws.com/rebar3/rebar3
ARG OTP_VERSION=28.1

# --- install deps
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf m4 \
      libncurses-dev libssl-dev xsltproc fop unixodbc-dev \
      ca-certificates curl git wget xz-utils pkg-config \
      libsodium23 libsodium-dev \
      ruby ruby-dev rubygems \
      rpm dpkg-dev gnupg libwxgtk3.2-dev \
    && gem install --no-document fpm

# --- kerl + OTP
RUN curl -fsSL https://raw.githubusercontent.com/kerl/kerl/master/kerl -o /usr/local/bin/kerl \
 && chmod +x /usr/local/bin/kerl

ENV KERL_BUILD_BACKEND=tarball \
    KERL_DOWNLOAD_DIR=/root/.kerl/archives \
    KERL_BUILD_DIR=/root/.kerl/builds \
    KERL_CONFIGURE_OPTIONS="--disable-debug --without-javac"

RUN kerl update releases \
 && kerl build ${OTP_VERSION} ${OTP_VERSION} \
 && mkdir -p /opt/erlang/${OTP_VERSION} \
 && kerl install ${OTP_VERSION} /opt/erlang/${OTP_VERSION}

# --- rebar3
RUN curl -fsSL ${REBAR3_URL} -o /usr/local/bin/rebar3 \
 && chmod +x /usr/local/bin/rebar3

ENV PATH="/opt/erlang/${OTP_VERSION}/bin:/usr/local/bin:${PATH}"

# --- Workspace
WORKDIR /opt/workspace

# COPY only project files that affect deps
COPY rebar.config  ./
RUN rebar3 get-deps

# --- Copy rest of the source
COPY . .

# --- Compile
RUN rebar3 compile

CMD ["/bin/bash"]

