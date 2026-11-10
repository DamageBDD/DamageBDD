#!/bin/sh
# Scoped ERM application-resource generation; ordinary builds are unchanged.
set -eu
case "${1:-release}" in release|tar) action=${1:-release} ;; *) echo 'usage: build.sh [release|tar]' >&2; exit 64 ;; esac
[ "$#" -le 1 ] || { echo 'usage: build.sh [release|tar]' >&2; exit 64; }
script=$(readlink -f -- "$0")
root=$(CDPATH= cd -- "$(dirname -- "$script")/../../../.." && pwd -P)
cd "$root"
export ERM_USERSPACE_BUILD=1
exec rebar3 as prod,erm_user "$action" -n erm_user
