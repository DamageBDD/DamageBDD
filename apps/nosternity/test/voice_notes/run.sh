#!/usr/bin/env bash
# Real Cowboy/Gun/auth/codec integration; only external model responses are fixtures.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"
work="$(mktemp -d "${TMPDIR:-/tmp}/nosternity-voice-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ebin" "$work/audio"
export VOICE_NOTE_FIXTURES="$work/audio"
ffmpeg -v error -f lavfi -i 'sine=frequency=220:sample_rate=16000:duration=1' -ac 1 -c:a libopus -b:a 24k "$work/audio/note.webm"
ffmpeg -v error -f lavfi -i 'sine=frequency=220:sample_rate=16000:duration=1' -ac 1 -c:a libopus -b:a 24k "$work/audio/note.ogg"
ffmpeg -v error -f lavfi -i 'sine=frequency=220:sample_rate=16000:duration=1' -ac 1 -c:a aac -b:a 24k "$work/audio/note.mp4"
ffmpeg -v error -f lavfi -i 'sine=frequency=220:sample_rate=16000:duration=2' -ac 1 -c:a libopus -b:a 24k "$work/audio/long.webm"
paths=()
for path in "$root"/_build/default/lib/*/ebin; do
    [[ -d "$path" ]] && paths+=( -pa "$path" )
done
erlc "${paths[@]}" -DTEST -I apps/damage/include -I apps/ecai/include -o "$work/ebin" \
    apps/ecai/src/ecai_voice_notes.erl apps/ecai/src/ecai_voice_wav.erl \
    apps/ecai/src/ecai_ollama_client.erl \
    apps/damage/src/damage_gun.erl apps/damage/src/damage_otp_compat.erl \
    apps/damage/src/damage_config.erl \
    apps/damage/src/damage_nostr_event.erl apps/damage/src/damage_browser_auth.erl \
    apps/damage/src/damage_browser_auth_http.erl \
    apps/nosternity/src/nosternity_voice_http.erl apps/nosternity/src/nosternity_auth*.erl \
    apps/nosternity/src/nosternity_config.erl apps/nosternity/src/nosternity_filter.erl \
    apps/nosternity/src/nosternity_storage.erl \
    apps/nosternity/src/nostrlib_schnorr.erl \
    apps/ecai/test/ecai_voice_notes_tests.erl apps/nosternity/test/nosternity_auth_tests.erl \
    apps/nosternity/test/nosternity_voice_provider_fixture.erl \
    apps/nosternity/test/nosternity_voice_http_tests.erl
erl "${paths[@]}" -pa "$work/ebin" -noshell -eval '
    case eunit:test([ecai_voice_notes_tests,nosternity_voice_http_tests],[verbose]) of
        ok -> halt(0); _ -> halt(1)
    end.'
