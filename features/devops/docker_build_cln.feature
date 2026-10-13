# Core Lightning release builds for the amd64 Linux targets used by this
# release feature: Ubuntu 22.04, Ubuntu 24.04, Ubuntu 26.04 and Fedora 40.
#
# Source policy:
#   * CLN is cloned directly from the official GitHub repository.
#   * Every CLN git submodule URL is checked and must also be on github.com.
#   * No curl/wget bootstrap installers (uv, rustup, etc.) are used.
#   * System build dependencies come only from each distribution's package manager.
#
# Since third-party Rust/uv bootstrap installers are intentionally excluded, these
# builds use --disable-rust. The resulting archives contain core CLN but not the
# Rust plugins cln-grpc, clnrest, cln-bip353 or wss-proxy.
#
# Each successful build is uploaded to IPFS, bound to metadata and a release NFT,
# then announced using the existing DamageBDD Nostr release-NFT publication step.
#
# Reproducibility policy:
#   * The upstream source tag remains v26.06.8.
#   * The DamageBDD package release is v26.06.8+build.1 so it cannot collide with
#     previously minted v26.06.8 package NFTs whose artifact bytes were different.
#   * SOURCE_DATE_EPOCH is derived from the source commit timestamp.
#   * Archive member ordering, timestamps and ownership are normalized.
#   * Compression metadata is normalized and each archive is generated twice and
#     compared before it is accepted.
Feature: Build and announce Core Lightning packages for supported Linux distributions

  Scenario: Build and announce Ubuntu 22.04 amd64 Core Lightning
    Given the build release discovery is configured
    When I build docker image "damagebdd/cln-builder:ubuntu-22.04" from this Dockerfile
    """
    FROM ubuntu:22.04

    ENV DEBIAN_FRONTEND=noninteractive
    ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf automake build-essential ca-certificates gettext git jq \
        libffi-dev libsecp256k1-dev libsodium-dev libsqlite3-dev libssl-dev \
        libtool lowdown net-tools pkg-config python3 python3-mako xz-utils \
        zlib1g-dev \
        && rm -rf /var/lib/apt/lists/*

    RUN groupadd --system lightning && \
        useradd --system --gid lightning --create-home \
        --home-dir /home/lightning --shell /bin/bash lightning && \
        mkdir -p /opt/workspace /build && \
        chown -R lightning:lightning /opt/workspace /build /home/lightning

    WORKDIR /opt/workspace
    USER lightning
    CMD ["/bin/sh"]
    """
    Then I run docker image tagged "damagebdd/cln-builder:ubuntu-22.04" as user "lightning"
    """
    set -eux
    umask 022
    test "$(id -un)" = lightning
    test "$(uname -m)" = x86_64

    rm -rf /build/lightning /build/release
    mkdir -p /build/release

    git clone --branch v26.06.8 --depth 1 \
      https://github.com/ElementsProject/lightning.git /build/lightning
    cd /build/lightning

    test "$(git config --get remote.origin.url)" = \
      "https://github.com/ElementsProject/lightning.git"
    NON_GITHUB=$(git config -f .gitmodules --get-regexp '\.url$' | \
      awk '{print $2}' | grep -Ev '^https://github\.com/' || true)
    test -z "$NON_GITHUB" || {
      echo "Refusing non-GitHub CLN submodule URL(s): $NON_GITHUB" >&2
      exit 1
    }
    git submodule update --init --recursive

    # msggen/__main__.py is a Python module, not a standalone shell script.
    # Keep the Git checkout pristine and invoke it through the distro Python.
    test -f contrib/msggen/msggen/__main__.py
    python3 --version
    python3 -c 'import mako'

    test "$(git describe --tags --exact-match HEAD)" = "v26.06.8"

    GIT_SHA=$(git rev-parse HEAD)
    test "${#GIT_SHA}" -eq 40

    # Use the immutable source commit timestamp for build/archive timestamps.
    SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
    test "$SOURCE_DATE_EPOCH" -gt 0
    printf '%s\n' "$SOURCE_DATE_EPOCH" > /build/release/SOURCE_DATE_EPOCH
    export SOURCE_DATE_EPOCH
    export TZ=UTC
    export LC_ALL=C
    export LANG=C

    # CLN's msggen Makefile uses $(PYTHON).  Without uv, configure leaves that
    # variable empty, causing /bin/sh to interpret __main__.py as shell code.
    # Use the distro-provided interpreter and let configure record it as well.
    export PYTHON=python3
    ./configure --disable-rust --prefix=/usr

    # Group parallel output by target so the failing target is visible near its
    # error instead of being buried under unrelated compiler output.
    MAKE_LOG=/build/release/make.log
    set +e
    /bin/bash -o pipefail -c 'make PYTHON=python3 --output-sync=target -j"$(nproc)" 2>&1 | tee "$1"' _ "$MAKE_LOG"
    MAKE_RC=$?
    set -e
    if [ "$MAKE_RC" -ne 0 ]; then
      echo "CLN make failed with exit code $MAKE_RC; final 250 log lines:" >&2
      tail -n 250 "$MAKE_LOG" >&2
      exit "$MAKE_RC"
    fi
    ./lightningd/lightningd --version

    STAGE=/build/release/clightning-v26.06.8+build.1-Ubuntu-22.04-amd64
    mkdir -p "$STAGE"
    make PYTHON=python3 install DESTDIR="$STAGE"
    test -x "$STAGE/usr/bin/lightningd"

    ARTIFACT=/build/release/clightning-v26.06.8+build.1-Ubuntu-22.04-amd64.tar.xz
    VERIFY_ARTIFACT="${ARTIFACT}.verify"

    # Normalize the tar stream. xz carries no filename/mtime header; explicit
    # compression options also avoid environment-dependent XZ_OPT behaviour.
    tar --sort=name --format=gnu \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -C /build/release -cf - "$(basename "$STAGE")" | \
      env -u XZ_OPT xz -6 --threads=1 --check=crc64 -c > "$ARTIFACT"

    tar --sort=name --format=gnu \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -C /build/release -cf - "$(basename "$STAGE")" | \
      env -u XZ_OPT xz -6 --threads=1 --check=crc64 -c > "$VERIFY_ARTIFACT"

    cmp -s "$ARTIFACT" "$VERIFY_ARTIFACT"
    rm -f "$VERIFY_ARTIFACT"

    SHA256=$(sha256sum "$ARTIFACT" | awk '{print $1}')
    printf '%s\n' "$GIT_SHA" > /build/release/GIT_COMMIT
    printf '%s\n' "$SHA256" > /build/release/ARTIFACT_SHA256
    test -s "$ARTIFACT"
    """
    Then I store file "/build/release/GIT_COMMIT" from the container in "git_sha"
    And I store file "/build/release/SOURCE_DATE_EPOCH" from the container in "source_date_epoch"
    And I store file "/build/release/ARTIFACT_SHA256" from the container in "artifact_sha256"
    And I copy file "/build/release/clightning-v26.06.8+build.1-Ubuntu-22.04-amd64.tar.xz" from the container to ipfs and store the hash in "asset_hash"

    When I set the JSON variable "meta"
    """
    {
      "name": "Core Lightning v26.06.8+build.1 Ubuntu 22.04 amd64",
      "description": "DamageBDD source build of Core Lightning from the official ElementsProject/lightning GitHub release tag.",
      "project": "Core Lightning",
      "release": "v26.06.8+build.1",
      "platform": "ubuntu-22.04-amd64",
      "architecture": "amd64",
      "artifact_type": "source_build_tarball",
      "package_format": "tar.xz",
      "source_repo": "https://github.com/ElementsProject/lightning.git",
      "source_tag": "v26.06.8",
      "build_user": "lightning",
      "rust_plugins": false,
      "reproducible_archive": true,
      "build_system": "docker + configure + make"
    }
    """
    When I set JSON key "file_ipfs" to "{{asset_hash}}" in variable "meta"
    And I set JSON key "git_sha" to "{{git_sha}}" in variable "meta"
    And I set JSON key "source_date_epoch" to "{{source_date_epoch}}" in variable "meta"
    And I set JSON key "sha256" to "{{artifact_sha256}}" in variable "meta"
    When I write JSON variable "meta" to file "meta.json"
    And I add the path "meta.json" to IPFS and store the hash in "meta_hash"
    When I mint generic build release "v26.06.8+build.1" for platform "ubuntu-22.04-amd64" with git SHA "{{git_sha}}" metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
    When I post the minted build release NFT to nostr

  Scenario: Build and announce Ubuntu 24.04 amd64 Core Lightning
    Given the build release discovery is configured
    When I build docker image "damagebdd/cln-builder:ubuntu-24.04" from this Dockerfile
    """
    FROM ubuntu:24.04

    ENV DEBIAN_FRONTEND=noninteractive
    ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf automake build-essential ca-certificates gettext git jq \
        libffi-dev libsecp256k1-dev libsodium-dev libsqlite3-dev libssl-dev \
        libtool lowdown net-tools pkg-config python3 python3-mako xz-utils \
        zlib1g-dev \
        && rm -rf /var/lib/apt/lists/*

    RUN groupadd --system lightning && \
        useradd --system --gid lightning --create-home \
        --home-dir /home/lightning --shell /bin/bash lightning && \
        mkdir -p /opt/workspace /build && \
        chown -R lightning:lightning /opt/workspace /build /home/lightning

    WORKDIR /opt/workspace
    USER lightning
    CMD ["/bin/sh"]
    """
    Then I run docker image tagged "damagebdd/cln-builder:ubuntu-24.04" as user "lightning"
    """
    set -eux
    umask 022
    test "$(id -un)" = lightning
    test "$(uname -m)" = x86_64

    rm -rf /build/lightning /build/release
    mkdir -p /build/release

    git clone --branch v26.06.8 --depth 1 \
      https://github.com/ElementsProject/lightning.git /build/lightning
    cd /build/lightning

    test "$(git config --get remote.origin.url)" = \
      "https://github.com/ElementsProject/lightning.git"
    NON_GITHUB=$(git config -f .gitmodules --get-regexp '\.url$' | \
      awk '{print $2}' | grep -Ev '^https://github\.com/' || true)
    test -z "$NON_GITHUB" || {
      echo "Refusing non-GitHub CLN submodule URL(s): $NON_GITHUB" >&2
      exit 1
    }
    git submodule update --init --recursive

    # msggen/__main__.py is a Python module, not a standalone shell script.
    # Keep the Git checkout pristine and invoke it through the distro Python.
    test -f contrib/msggen/msggen/__main__.py
    python3 --version
    python3 -c 'import mako'

    test "$(git describe --tags --exact-match HEAD)" = "v26.06.8"

    GIT_SHA=$(git rev-parse HEAD)
    test "${#GIT_SHA}" -eq 40

    # Use the immutable source commit timestamp for build/archive timestamps.
    SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
    test "$SOURCE_DATE_EPOCH" -gt 0
    printf '%s\n' "$SOURCE_DATE_EPOCH" > /build/release/SOURCE_DATE_EPOCH
    export SOURCE_DATE_EPOCH
    export TZ=UTC
    export LC_ALL=C
    export LANG=C

    # CLN's msggen Makefile uses $(PYTHON).  Without uv, configure leaves that
    # variable empty, causing /bin/sh to interpret __main__.py as shell code.
    # Use the distro-provided interpreter and let configure record it as well.
    export PYTHON=python3
    ./configure --disable-rust --prefix=/usr

    # Group parallel output by target so the failing target is visible near its
    # error instead of being buried under unrelated compiler output.
    MAKE_LOG=/build/release/make.log
    set +e
    /bin/bash -o pipefail -c 'make PYTHON=python3 --output-sync=target -j"$(nproc)" 2>&1 | tee "$1"' _ "$MAKE_LOG"
    MAKE_RC=$?
    set -e
    if [ "$MAKE_RC" -ne 0 ]; then
      echo "CLN make failed with exit code $MAKE_RC; final 250 log lines:" >&2
      tail -n 250 "$MAKE_LOG" >&2
      exit "$MAKE_RC"
    fi
    ./lightningd/lightningd --version

    STAGE=/build/release/clightning-v26.06.8+build.1-Ubuntu-24.04-amd64
    mkdir -p "$STAGE"
    make PYTHON=python3 install DESTDIR="$STAGE"
    test -x "$STAGE/usr/bin/lightningd"

    ARTIFACT=/build/release/clightning-v26.06.8+build.1-Ubuntu-24.04-amd64.tar.xz
    VERIFY_ARTIFACT="${ARTIFACT}.verify"

    # Normalize the tar stream. xz carries no filename/mtime header; explicit
    # compression options also avoid environment-dependent XZ_OPT behaviour.
    tar --sort=name --format=gnu \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -C /build/release -cf - "$(basename "$STAGE")" | \
      env -u XZ_OPT xz -6 --threads=1 --check=crc64 -c > "$ARTIFACT"

    tar --sort=name --format=gnu \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -C /build/release -cf - "$(basename "$STAGE")" | \
      env -u XZ_OPT xz -6 --threads=1 --check=crc64 -c > "$VERIFY_ARTIFACT"

    cmp -s "$ARTIFACT" "$VERIFY_ARTIFACT"
    rm -f "$VERIFY_ARTIFACT"

    SHA256=$(sha256sum "$ARTIFACT" | awk '{print $1}')
    printf '%s\n' "$GIT_SHA" > /build/release/GIT_COMMIT
    printf '%s\n' "$SHA256" > /build/release/ARTIFACT_SHA256
    test -s "$ARTIFACT"
    """
    Then I store file "/build/release/GIT_COMMIT" from the container in "git_sha"
    And I store file "/build/release/SOURCE_DATE_EPOCH" from the container in "source_date_epoch"
    And I store file "/build/release/ARTIFACT_SHA256" from the container in "artifact_sha256"
    And I copy file "/build/release/clightning-v26.06.8+build.1-Ubuntu-24.04-amd64.tar.xz" from the container to ipfs and store the hash in "asset_hash"

    When I set the JSON variable "meta"
    """
    {
      "name": "Core Lightning v26.06.8+build.1 Ubuntu 24.04 amd64",
      "description": "DamageBDD source build of Core Lightning from the official ElementsProject/lightning GitHub release tag.",
      "project": "Core Lightning",
      "release": "v26.06.8+build.1",
      "platform": "ubuntu-24.04-amd64",
      "architecture": "amd64",
      "artifact_type": "source_build_tarball",
      "package_format": "tar.xz",
      "source_repo": "https://github.com/ElementsProject/lightning.git",
      "source_tag": "v26.06.8",
      "build_user": "lightning",
      "rust_plugins": false,
      "reproducible_archive": true,
      "build_system": "docker + configure + make"
    }
    """
    When I set JSON key "file_ipfs" to "{{asset_hash}}" in variable "meta"
    And I set JSON key "git_sha" to "{{git_sha}}" in variable "meta"
    And I set JSON key "source_date_epoch" to "{{source_date_epoch}}" in variable "meta"
    And I set JSON key "sha256" to "{{artifact_sha256}}" in variable "meta"
    When I write JSON variable "meta" to file "meta.json"
    And I add the path "meta.json" to IPFS and store the hash in "meta_hash"
    When I mint generic build release "v26.06.8+build.1" for platform "ubuntu-24.04-amd64" with git SHA "{{git_sha}}" metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
    When I post the minted build release NFT to nostr

  Scenario: Build and announce Ubuntu 26.04 amd64 Core Lightning
    Given the build release discovery is configured
    When I build docker image "damagebdd/cln-builder:ubuntu-26.04" from this Dockerfile
    """
    FROM ubuntu:26.04

    ENV DEBIAN_FRONTEND=noninteractive
    ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf automake build-essential ca-certificates gettext git jq \
        libffi-dev libsecp256k1-dev libsodium-dev libsqlite3-dev libssl-dev \
        libtool lowdown net-tools pkg-config python3 python3-mako xz-utils \
        zlib1g-dev \
        && rm -rf /var/lib/apt/lists/*

    RUN groupadd --system lightning && \
        useradd --system --gid lightning --create-home \
        --home-dir /home/lightning --shell /bin/bash lightning && \
        mkdir -p /opt/workspace /build && \
        chown -R lightning:lightning /opt/workspace /build /home/lightning

    WORKDIR /opt/workspace
    USER lightning
    CMD ["/bin/sh"]
    """
    Then I run docker image tagged "damagebdd/cln-builder:ubuntu-26.04" as user "lightning"
    """
    set -eux
    umask 022
    test "$(id -un)" = lightning
    test "$(uname -m)" = x86_64

    rm -rf /build/lightning /build/release
    mkdir -p /build/release

    git clone --branch v26.06.8 --depth 1 \
      https://github.com/ElementsProject/lightning.git /build/lightning
    cd /build/lightning

    test "$(git config --get remote.origin.url)" = \
      "https://github.com/ElementsProject/lightning.git"
    NON_GITHUB=$(git config -f .gitmodules --get-regexp '\.url$' | \
      awk '{print $2}' | grep -Ev '^https://github\.com/' || true)
    test -z "$NON_GITHUB" || {
      echo "Refusing non-GitHub CLN submodule URL(s): $NON_GITHUB" >&2
      exit 1
    }
    git submodule update --init --recursive

    # msggen/__main__.py is a Python module, not a standalone shell script.
    # Keep the Git checkout pristine and invoke it through the distro Python.
    test -f contrib/msggen/msggen/__main__.py
    python3 --version
    python3 -c 'import mako'

    test "$(git describe --tags --exact-match HEAD)" = "v26.06.8"

    GIT_SHA=$(git rev-parse HEAD)
    test "${#GIT_SHA}" -eq 40

    # Use the immutable source commit timestamp for build/archive timestamps.
    SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
    test "$SOURCE_DATE_EPOCH" -gt 0
    printf '%s\n' "$SOURCE_DATE_EPOCH" > /build/release/SOURCE_DATE_EPOCH
    export SOURCE_DATE_EPOCH
    export TZ=UTC
    export LC_ALL=C
    export LANG=C

    # CLN's msggen Makefile uses $(PYTHON).  Without uv, configure leaves that
    # variable empty, causing /bin/sh to interpret __main__.py as shell code.
    # Use the distro-provided interpreter and let configure record it as well.
    export PYTHON=python3
    ./configure --disable-rust --prefix=/usr

    # Group parallel output by target so the failing target is visible near its
    # error instead of being buried under unrelated compiler output.
    MAKE_LOG=/build/release/make.log
    set +e
    /bin/bash -o pipefail -c 'make PYTHON=python3 --output-sync=target -j"$(nproc)" 2>&1 | tee "$1"' _ "$MAKE_LOG"
    MAKE_RC=$?
    set -e
    if [ "$MAKE_RC" -ne 0 ]; then
      echo "CLN make failed with exit code $MAKE_RC; final 250 log lines:" >&2
      tail -n 250 "$MAKE_LOG" >&2
      exit "$MAKE_RC"
    fi
    ./lightningd/lightningd --version

    STAGE=/build/release/clightning-v26.06.8+build.1-Ubuntu-26.04-amd64
    mkdir -p "$STAGE"
    make PYTHON=python3 install DESTDIR="$STAGE"
    test -x "$STAGE/usr/bin/lightningd"

    ARTIFACT=/build/release/clightning-v26.06.8+build.1-Ubuntu-26.04-amd64.tar.xz
    VERIFY_ARTIFACT="${ARTIFACT}.verify"

    # Normalize the tar stream. xz carries no filename/mtime header; explicit
    # compression options also avoid environment-dependent XZ_OPT behaviour.
    tar --sort=name --format=gnu \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -C /build/release -cf - "$(basename "$STAGE")" | \
      env -u XZ_OPT xz -6 --threads=1 --check=crc64 -c > "$ARTIFACT"

    tar --sort=name --format=gnu \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -C /build/release -cf - "$(basename "$STAGE")" | \
      env -u XZ_OPT xz -6 --threads=1 --check=crc64 -c > "$VERIFY_ARTIFACT"

    cmp -s "$ARTIFACT" "$VERIFY_ARTIFACT"
    rm -f "$VERIFY_ARTIFACT"

    SHA256=$(sha256sum "$ARTIFACT" | awk '{print $1}')
    printf '%s\n' "$GIT_SHA" > /build/release/GIT_COMMIT
    printf '%s\n' "$SHA256" > /build/release/ARTIFACT_SHA256
    test -s "$ARTIFACT"
    """
    Then I store file "/build/release/GIT_COMMIT" from the container in "git_sha"
    And I store file "/build/release/SOURCE_DATE_EPOCH" from the container in "source_date_epoch"
    And I store file "/build/release/ARTIFACT_SHA256" from the container in "artifact_sha256"
    And I copy file "/build/release/clightning-v26.06.8+build.1-Ubuntu-26.04-amd64.tar.xz" from the container to ipfs and store the hash in "asset_hash"

    When I set the JSON variable "meta"
    """
    {
      "name": "Core Lightning v26.06.8+build.1 Ubuntu 26.04 amd64",
      "description": "DamageBDD source build of Core Lightning from the official ElementsProject/lightning GitHub release tag.",
      "project": "Core Lightning",
      "release": "v26.06.8+build.1",
      "platform": "ubuntu-26.04-amd64",
      "architecture": "amd64",
      "artifact_type": "source_build_tarball",
      "package_format": "tar.xz",
      "source_repo": "https://github.com/ElementsProject/lightning.git",
      "source_tag": "v26.06.8",
      "build_user": "lightning",
      "rust_plugins": false,
      "reproducible_archive": true,
      "build_system": "docker + configure + make"
    }
    """
    When I set JSON key "file_ipfs" to "{{asset_hash}}" in variable "meta"
    And I set JSON key "git_sha" to "{{git_sha}}" in variable "meta"
    And I set JSON key "source_date_epoch" to "{{source_date_epoch}}" in variable "meta"
    And I set JSON key "sha256" to "{{artifact_sha256}}" in variable "meta"
    When I write JSON variable "meta" to file "meta.json"
    And I add the path "meta.json" to IPFS and store the hash in "meta_hash"
    When I mint generic build release "v26.06.8+build.1" for platform "ubuntu-26.04-amd64" with git SHA "{{git_sha}}" metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
    When I post the minted build release NFT to nostr

  Scenario: Build and announce Fedora 40 amd64 Core Lightning
    Given the build release discovery is configured
    When I build docker image "damagebdd/cln-builder:fedora-40" from this Dockerfile
    """
    FROM fedora:40

    ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

    RUN dnf -y install \
        autoconf automake ca-certificates clang gcc gcc-c++ gettext git gzip jq lowdown \
        libffi-devel libsodium-devel libtool make net-tools openssl-devel \
        pkgconf-pkg-config python3 python3-devel python3-mako sed sqlite-devel \
        tar which xz zlib-devel \
        && dnf clean all

    RUN groupadd --system lightning && \
        useradd --system --gid lightning --create-home \
        --home-dir /home/lightning --shell /bin/bash lightning && \
        mkdir -p /opt/workspace /build && \
        chown -R lightning:lightning /opt/workspace /build /home/lightning

    WORKDIR /opt/workspace
    USER lightning
    CMD ["/bin/sh"]
    """
    Then I run docker image tagged "damagebdd/cln-builder:fedora-40" as user "lightning"
    """
    set -eux
    umask 022
    test "$(id -un)" = lightning
    test "$(uname -m)" = x86_64

    rm -rf /build/lightning /build/release
    mkdir -p /build/release

    git clone --branch v26.06.8 --depth 1 \
      https://github.com/ElementsProject/lightning.git /build/lightning
    cd /build/lightning

    test "$(git config --get remote.origin.url)" = \
      "https://github.com/ElementsProject/lightning.git"
    NON_GITHUB=$(git config -f .gitmodules --get-regexp '\.url$' | \
      awk '{print $2}' | grep -Ev '^https://github\.com/' || true)
    test -z "$NON_GITHUB" || {
      echo "Refusing non-GitHub CLN submodule URL(s): $NON_GITHUB" >&2
      exit 1
    }
    git submodule update --init --recursive

    # msggen/__main__.py is a Python module, not a standalone shell script.
    # Keep the Git checkout pristine and invoke it through the distro Python.
    test -f contrib/msggen/msggen/__main__.py
    python3 --version
    python3 -c 'import mako'
    command -v lowdown >/dev/null

    test "$(git describe --tags --exact-match HEAD)" = "v26.06.8"

    GIT_SHA=$(git rev-parse HEAD)
    test "${#GIT_SHA}" -eq 40

    # Use the immutable source commit timestamp for build/archive timestamps.
    SOURCE_DATE_EPOCH=$(git show -s --format=%ct HEAD)
    test "$SOURCE_DATE_EPOCH" -gt 0
    printf '%s\n' "$SOURCE_DATE_EPOCH" > /build/release/SOURCE_DATE_EPOCH
    export SOURCE_DATE_EPOCH
    export TZ=UTC
    export LC_ALL=C
    export LANG=C

    # CLN's msggen Makefile uses $(PYTHON).  Without uv, configure leaves that
    # variable empty, causing /bin/sh to interpret __main__.py as shell code.
    # Use the distro-provided interpreter and let configure record it as well.
    export PYTHON=python3
    ./configure --disable-rust --prefix=/usr

    # Group parallel output by target so the failing target is visible near its
    # error instead of being buried under unrelated compiler output.
    MAKE_LOG=/build/release/make.log
    set +e
    /bin/bash -o pipefail -c 'make PYTHON=python3 --output-sync=target -j"$(nproc)" 2>&1 | tee "$1"' _ "$MAKE_LOG"
    MAKE_RC=$?
    set -e
    if [ "$MAKE_RC" -ne 0 ]; then
      echo "CLN make failed with exit code $MAKE_RC; final 250 log lines:" >&2
      tail -n 250 "$MAKE_LOG" >&2
      exit "$MAKE_RC"
    fi
    ./lightningd/lightningd --version

    STAGE=/build/release/clightning-v26.06.8+build.1-Fedora-40-amd64
    mkdir -p "$STAGE"
    make PYTHON=python3 install DESTDIR="$STAGE"
    test -x "$STAGE/usr/bin/lightningd"

    ARTIFACT=/build/release/clightning-v26.06.8+build.1-Fedora-40-amd64.tar.gz
    VERIFY_ARTIFACT="${ARTIFACT}.verify"

    # Normalize the tar stream and suppress gzip filename/timestamp metadata.
    tar --sort=name --format=gnu \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -C /build/release -cf - "$(basename "$STAGE")" | \
      gzip -n -9 > "$ARTIFACT"

    tar --sort=name --format=gnu \
      --mtime="@${SOURCE_DATE_EPOCH}" \
      --owner=0 --group=0 --numeric-owner \
      -C /build/release -cf - "$(basename "$STAGE")" | \
      gzip -n -9 > "$VERIFY_ARTIFACT"

    cmp -s "$ARTIFACT" "$VERIFY_ARTIFACT"
    rm -f "$VERIFY_ARTIFACT"

    SHA256=$(sha256sum "$ARTIFACT" | awk '{print $1}')
    printf '%s\n' "$GIT_SHA" > /build/release/GIT_COMMIT
    printf '%s\n' "$SHA256" > /build/release/ARTIFACT_SHA256
    test -s "$ARTIFACT"
    """
    Then I store file "/build/release/GIT_COMMIT" from the container in "git_sha"
    And I store file "/build/release/SOURCE_DATE_EPOCH" from the container in "source_date_epoch"
    And I store file "/build/release/ARTIFACT_SHA256" from the container in "artifact_sha256"
    And I copy file "/build/release/clightning-v26.06.8+build.1-Fedora-40-amd64.tar.gz" from the container to ipfs and store the hash in "asset_hash"

    When I set the JSON variable "meta"
    """
    {
      "name": "Core Lightning v26.06.8+build.1 Fedora 40 amd64",
      "description": "DamageBDD source build of Core Lightning from the official ElementsProject/lightning GitHub release tag.",
      "project": "Core Lightning",
      "release": "v26.06.8+build.1",
      "platform": "fedora-40-amd64",
      "architecture": "amd64",
      "artifact_type": "source_build_tarball",
      "package_format": "tar.gz",
      "source_repo": "https://github.com/ElementsProject/lightning.git",
      "source_tag": "v26.06.8",
      "build_user": "lightning",
      "rust_plugins": false,
      "reproducible_archive": true,
      "build_system": "docker + configure + make"
    }
    """
    When I set JSON key "file_ipfs" to "{{asset_hash}}" in variable "meta"
    And I set JSON key "git_sha" to "{{git_sha}}" in variable "meta"
    And I set JSON key "source_date_epoch" to "{{source_date_epoch}}" in variable "meta"
    And I set JSON key "sha256" to "{{artifact_sha256}}" in variable "meta"
    When I write JSON variable "meta" to file "meta.json"
    And I add the path "meta.json" to IPFS and store the hash in "meta_hash"
    When I mint generic build release "v26.06.8+build.1" for platform "fedora-40-amd64" with git SHA "{{git_sha}}" metadata IPFS hash in "meta_hash" and asset hash in "asset_hash"
    And I store the mint result in "mint"
    When I post the minted build release NFT to nostr
