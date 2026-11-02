#!/bin/sh
set -eu
ECDJ_APP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ECDJ_ECAI_ROOT=$(CDPATH= cd -- "$ECDJ_APP_ROOT/../ecai" && pwd)
ECDJ_TEST_DIR=$(mktemp -d)
export ECDJ_APP_ROOT ECDJ_ECAI_ROOT ECDJ_TEST_DIR
trap 'rm -rf "$ECDJ_TEST_DIR"' EXIT INT TERM
"${ERL:-erl}" -noshell -eval '
 App=os:getenv("ECDJ_APP_ROOT"), Ecai=os:getenv("ECDJ_ECAI_ROOT"), Tmp=os:getenv("ECDJ_TEST_DIR"),
 case code:which(jsx) of non_existing->io:format("JSX is required; set ERL_LIBS to your umbrella dependency directory.~n"),halt(1);_->ok end,
 Names=["erm_dj","erm_dj_http","erm_dj_ektoplazm","erm_dj_media","erm_dj_widget","erm_sup","erm_mpv_proc"],
 ENames=["ecai_dj_package","ecai_music_recommender","ecai_terms","ecai_tokenizer"],
 Tests=[erm_dj_http_tests,erm_dj_ektoplazm_tests,erm_dj_media_tests,erm_dj_widget_tests,erm_dj_mpv_tests,
        ecai_dj_package_tests,ecai_music_recommender_tests],
 Files=[filename:join([App,"src",N++".erl"])||N<-Names]++
       [filename:join([Ecai,"src",N++".erl"])||N<-ENames]++
       [filename:join([case lists:prefix("ecai",atom_to_list(M)) of true->Ecai;false->App end,
                       "test",atom_to_list(M)++".erl"])||M<-Tests],
 R=[compile:file(F,[warnings_as_errors,return_errors,return_warnings,{d,list_to_atom("TEST")},{i,filename:join(App,"include")},
                     {outdir,Tmp}])||F<-Files],
 case lists:all(fun({ok,_,[]})->true;(_)->false end,R) of false->io:format("~p~n",[R]),halt(1);true->ok end,
 true=code:add_patha(Tmp),ok=file:set_cwd(filename:join(App,"../..")),
 case eunit:test(Tests,[verbose]) of ok->halt(0);_->halt(1) end.'
ERL="${ERL:-erl}" "$ECDJ_APP_ROOT/test/dj_http_isolated/run.sh"
ERL="${ERL:-erl}" "$ECDJ_APP_ROOT/test/dj_service_isolated/run.sh"
