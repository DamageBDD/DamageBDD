#!/bin/sh
set -eu
ECDJ_APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ECDJ_TEST_DIR=$(mktemp -d)
export ECDJ_APP_ROOT ECDJ_TEST_DIR
trap 'rm -rf "$ECDJ_TEST_DIR"' EXIT INT TERM
cp "$ECDJ_APP_ROOT/test/dj_http_isolated/gun.erl.fixture" "$ECDJ_TEST_DIR/gun.erl"
"${ERL:-erl}" -noshell -eval '
 App=os:getenv("ECDJ_APP_ROOT"), Tmp=os:getenv("ECDJ_TEST_DIR"),
 Files=[filename:join(Tmp,"gun.erl"), filename:join(App,"src/erm_dj_http.erl"),
        filename:join(App,"test/dj_http_isolated/erm_dj_http_protocol_tests.erl")],
 Results=[compile:file(F,[warnings_as_errors,return_errors,return_warnings,{outdir,Tmp}]) || F<-Files],
 case lists:all(fun({ok,_,[]})->true;(_)->false end, Results) of
  false -> io:format("~p~n",[Results]), halt(1);
  true -> ok
 end,
 ok=file:write_file(filename:join(Tmp,"gun.app"),
   "{application,gun,[{description,\"test transport\"},{vsn,\"test\"},{modules,[gun]},{applications,[kernel,stdlib,ssl]}]}.\n"),
 true=code:add_patha(Tmp),
 case eunit:test(erm_dj_http_protocol_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
