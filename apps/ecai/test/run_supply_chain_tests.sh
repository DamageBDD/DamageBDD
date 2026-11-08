#!/bin/sh
# Standalone model/service tests: no NIF, Cowboy, Damage or external solver needed.
# HTTP integration itself still needs the complete DamageBDD umbrella.
set -eu
APP=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
command -v erl >/dev/null 2>&1 && command -v erlc >/dev/null 2>&1 || {
  printf '%s\n' 'Erlang/OTP 27+ (erl, erlc and EUnit) is required.' >&2
  exit 2
}
erl -noshell -eval 'case list_to_integer(erlang:system_info(otp_release)) >= 27 of true -> halt(0); false -> halt(2) end.' || {
  printf '%s\n' 'OTP 27+ is required for the stdlib JSON codec.' >&2; exit 2;
}
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/ecai-supply-chain-beam.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM
for source in ecai_paths ecai_tokenizer ecai_terms ecai_supply_chain_util ecai_supply_chain_model \
  ecai_supply_chain_validator ecai_supply_chain_planner ecai_supply_chain_cases \
  ecai_supply_chain_task ecai_supply_chain_guest ecai_supply_chain_srv ecai_supply_chain_http; do
  erlc -Werror -o "$BUILD" "$APP/src/$source.erl"
done
erlc -Werror -o "$BUILD" "$APP/test/ecai_supply_chain_tests.erl"
erlc -Werror -o "$BUILD" "$APP/test/ecai_supply_chain_public_tests.erl"
erl -noshell -pa "$BUILD" -eval '
  {ok,_}=application:ensure_all_started(crypto),
  application:set_env(ecai,supply_chain_curve_addresses,false),
  case eunit:test([ecai_supply_chain_tests,ecai_supply_chain_public_tests],[verbose]) of ok -> halt(0); _ -> halt(1) end.'
