#!/bin/sh
set -eu
model_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
MODEL_TEST_TMP=$(mktemp -d)
export MODEL_TEST_TMP
trap 'rm -rf "$MODEL_TEST_TMP"' EXIT HUP INT TERM
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj '/CN=Model Test CA' \
  -keyout "$MODEL_TEST_TMP/ca.key" -out "$MODEL_TEST_TMP/ca.pem" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj '/CN=localhost' \
  -keyout "$MODEL_TEST_TMP/key.pem" -out "$MODEL_TEST_TMP/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > "$MODEL_TEST_TMP/ext.cnf"
openssl x509 -req -days 1 -in "$MODEL_TEST_TMP/server.csr" \
  -CA "$MODEL_TEST_TMP/ca.pem" -CAkey "$MODEL_TEST_TMP/ca.key" -CAcreateserial \
  -extfile "$MODEL_TEST_TMP/ext.cnf" -out "$MODEL_TEST_TMP/cert.pem" >/dev/null 2>&1
cp "$model_root/apps/erm/test/model_pull_isolated/erm_model_pull_tests.erl.src" "$MODEL_TEST_TMP/erm_model_pull_tests.erl"
cc -Wall -Wextra -Werror "$model_root/apps/erm/test/model_pull_isolated/fake_tts.c" -o "$MODEL_TEST_TMP/fake_tts"
erlc -Werror -o "$MODEL_TEST_TMP" "$model_root"/apps/erm/src/erm_model_*.erl "$model_root/apps/erm/src/erm_tts.erl" "$model_root/apps/erm/src/erm_tts_paths.erl" "$MODEL_TEST_TMP/erm_model_pull_tests.erl"
erl +S 2 -noshell -pa "$MODEL_TEST_TMP" -eval \
 'case eunit:test(erm_model_pull_tests,[verbose]) of ok->halt(0);_->halt(1) end.'
