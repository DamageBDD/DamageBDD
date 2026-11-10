#!/bin/sh
set -eu
if [ "${ERM_USERSPACE_BUILD:-}" != 1 ]; then
    echo 'ERM userspace builds must use apps/erm/packaging/userspace/build.sh [release|tar]' >&2
    exit 1
fi
