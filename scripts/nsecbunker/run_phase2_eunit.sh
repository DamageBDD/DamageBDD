#!/usr/bin/env sh
set -eu
rebar3 compile
rebar3 eunit --module=damage_nsecbunker_phase2_contract_tests
