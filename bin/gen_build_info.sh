#!/bin/sh
SHA=$(git rev-parse HEAD 2>/dev/null || echo unknown)
SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ENV=${DAMAGE_BUILD_ENV:-dev}

rm apps/damage/src/damage_build_info.erl -f
cat > apps/damage/src/damage_build_info.erl <<EOF
%%%-------------------------------------------------------------------
%%% AUTO-GENERATED — DO NOT EDIT
%%%-------------------------------------------------------------------
-module(damage_build_info).
-export([
    git_sha/0,
    git_sha_short/0,
    build_time/0,
    build_env/0
]).
git_sha() -> <<"$SHA">>.
git_sha_short() -> <<"$SHORT">>.
build_time() -> <<"$TS">>.
build_env() -> <<"$ENV">>.
EOF
