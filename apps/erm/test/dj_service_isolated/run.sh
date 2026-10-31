#!/bin/sh
set -eu
ECDJ_APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ECDJ_ECAI_ROOT=$(CDPATH= cd -- "$ECDJ_APP_ROOT/../ecai" && pwd)
ECDJ_TEST_DIR=$(mktemp -d)
export ECDJ_APP_ROOT ECDJ_ECAI_ROOT ECDJ_TEST_DIR
trap 'rm -rf "$ECDJ_TEST_DIR"' EXIT INT TERM
for ECDJ_STUB in erm_dj_ektoplazm playlist erm_mpv_proc erm_sup; do
 cp "$ECDJ_APP_ROOT/test/dj_service_isolated/$ECDJ_STUB.erl.fixture" "$ECDJ_TEST_DIR/$ECDJ_STUB.erl"
done
"${ERL:-erl}" -noshell -eval '
 App=os:getenv("ECDJ_APP_ROOT"), Ecai=os:getenv("ECDJ_ECAI_ROOT"), Tmp=os:getenv("ECDJ_TEST_DIR"),
 Files=filelib:wildcard(filename:join(Tmp,"*.erl"))++
 [filename:join([App,"src",N++".erl"])||N<-["erm_dj","erm_dj_http","erm_dj_media"]]++
 [filename:join([Ecai,"src",N++".erl"])||N<-["ecai_dj_package","ecai_music_recommender"]]++
 [filename:join(App,"test/dj_service_isolated/erm_dj_service_tests.erl")],
 R=[compile:file(F,[warnings_as_errors,return_errors,return_warnings,{outdir,Tmp}])||F<-Files],
 case lists:all(fun({ok,_,[]})->true;(_)->false end,R) of false->io:format("~p~n",[R]),halt(1);true->ok end,
 true=code:add_patha(Tmp),
 case eunit:test(erm_dj_service_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
