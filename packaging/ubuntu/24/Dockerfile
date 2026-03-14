# syntax=docker/dockerfile:1
# Linux Mint 22 (Wilma) base — stays Mint-only per your requirement
FROM ubuntu:noble
#FROM ubuntu:22.04


ARG DEBIAN_FRONTEND=noninteractive
ARG REPO_URL=https://github.com/DamageBDD/DamageBDD.git
ARG REPO_REF=develop   # or a tag/sha
ARG REBAR3_URL=https://s3.amazonaws.com/rebar3/rebar3
ARG OTP_VERSION=28.3
WORKDIR /opt/workspace


# Optional: Use a specific mirror for speed
#RUN sed -i 's|http://archive.ubuntu.com|http://ubuntu.mirror.serveraustralia.com|g' /etc/apt/sources.list
RUN set -eux; \
  printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
    > /etc/apt/apt.conf.d/99retries; \
  apt-get update; \
  apt-get install -y --no-install-recommends git\
      build-essential autoconf m4 \
      libncurses-dev libssl-dev xsltproc fop unixodbc-dev \
      ca-certificates curl git wget xz-utils pkg-config \
      libsodium23 libsodium-dev \
      ruby ruby-dev rubygems \
      rpm dpkg-dev gnupg rsync \
    nvidia-cuda-toolkit \
      pkg-config \
      libgtk-4-dev \
      libcairo2-dev \
      libpango1.0-dev \
      libglib2.0-dev \
      libgdk-pixbuf-2.0-dev \
      libharfbuzz-dev \
      libgraphene-1.0-dev \
    && gem install --no-document fpm \
 && rm -rf /var/lib/apt/lists/*

# --- kerl + OTP
RUN curl -fsSL https://raw.githubusercontent.com/kerl/kerl/master/kerl -o /usr/local/bin/kerl \
 && chmod +x /usr/local/bin/kerl

ENV KERL_BUILD_BACKEND=git \
    KERL_DOWNLOAD_DIR=/root/.kerl/archives \
    KERL_BUILD_DIR=/root/.kerl/builds \
    KERL_CONFIGURE_OPTIONS="--disable-debug --without-javac"

RUN kerl update releases 
RUN kerl list releases 
RUN kerl build ${OTP_VERSION} ${OTP_VERSION} 
RUN mkdir -p /opt/erlang/${OTP_VERSION} 
RUN kerl install ${OTP_VERSION} /opt/erlang/${OTP_VERSION}

# --- rebar3
RUN curl -fsSL ${REBAR3_URL} -o /usr/local/bin/rebar3 \
 && chmod +x /usr/local/bin/rebar3

ENV PATH="/opt/erlang/${OTP_VERSION}/bin:/usr/local/bin:${PATH}"

# ====== SMART DEPS CACHE LAYER (Git-only) ======
# We create a tiny sparse checkout that includes ONLY rebar configs
# so Docker’s cache invalidates this layer ONLY when deps change.
RUN mkdir -p /opt/deps && cd /opt/deps \
 && git init . \
 && git remote add origin "$REPO_URL" \
 && git fetch --depth=1 origin "$REPO_REF" \
 && git config core.sparseCheckout true \
 && printf "%s\n" \
      "rebar.config" \
      "rebar.lock" \
      "apps" \
    > .git/info/sparse-checkout \
 && git checkout FETCH_HEAD \
 # prune everything except rebar configs inside apps/
 && find apps -type f ! -name "rebar.config" ! -name "rebar.lock" -delete || true \
 && find apps -type d -empty -delete || true

# Copy only the config files into the build workspace for deps resolution.
# If rebar configs didn’t change, this layer (and the deps fetch) is reused.
RUN set -e \
 && [ -f /opt/deps/rebar.config ] && cp /opt/deps/rebar.config /opt/workspace/ || true \
 && [ -f /opt/deps/rebar.lock ]   && cp /opt/deps/rebar.lock   /opt/workspace/ || true \
 && if [ -d /opt/deps/apps ]; then \
      mkdir -p /opt/workspace/apps && \
      find /opt/deps/apps -type f -name "rebar.config" -exec bash -lc 'd=$(dirname "{}" | sed "s#/opt/deps/##"); mkdir -p "/opt/workspace/$d"; cp "{}" "/opt/workspace/$d/"' \; && \
      find /opt/deps/apps -type f -name "rebar.lock"   -exec bash -lc 'd=$(dirname "{}" | sed "s#/opt/deps/##"); mkdir -p "/opt/workspace/$d"; cp "{}" "/opt/workspace/$d/"' \; \
    ; fi \
 && rm -rf /opt/deps

# Fetch git deps. This step is cached unless the copied configs changed.
RUN rebar3 update && rebar3 get-deps

# ====== SOURCE LAYER ======
# Now bring in the full repository (single shallow clone).
# If only source changed (not deps), the deps layer above stays cached.
RUN git clone --depth=100 --branch "$REPO_REF" "$REPO_URL" /opt/workspace/fullsrc

# Sync full source over the minimal config workspace (without nuking _build from deps step)
# so we retain the cached deps artifacts when possible.
# Copy full source into /opt/workspace but keep any cached _build
RUN set -eu \
 && (cd /opt/workspace/fullsrc \
     && tar -cf - \
          --exclude='./_build' \
          .) \
  | tar -C /opt/workspace -xpf - \
 && rm -rf /opt/workspace/fullsrc


# Build
#RUN rebar3 as prod compile && rebar3 as prod release
#
## --- Runtime (still Mint; if you prefer smaller, switch to a minimal base) ---
## Keeping Mint-only per your request.
#WORKDIR /opt/app
#RUN mkdir -p /opt/app
#COPY --chown=root:root /opt/workspace/_build/prod/rel/* /opt/app/
RUN groupadd -r damage && \
    useradd -r -g damage -d /home/damage -m -s /bin/bash damage
RUN mkdir /out
RUN chown -R damage:damage /opt/workspace
USER damage
EXPOSE 8080
CMD ["/opt/damage/bin/damage", "foreground"]

