# Piper final audio chunk fix

The native worker discarded the last chunk before copying its samples whenever
`piper_synthesize_next` returned `PIPER_DONE`. The libpiper source pinned by our
setup script returns this status together with the last sentence's audio:

https://github.com/OHF-Voice/piper1-gpl/blob/efffbfb226bfb511ebbcf55d0cecd8b35a89743d/libpiper/src/piper.cpp

Consequences: a single sentence raised `empty_audio`; a multi-sentence utterance
silently lost its last sentence. Reconnection made `ready` true again without
fixing synthesis. Readiness only established that the synthesizer loaded.

The worker now accepts OK and DONE statuses, validates/copies any supplied
samples, then stops on DONE or `is_last`. It also supports the older convention
where the last chunk returns OK and a subsequent call returns empty DONE.
Nonempty chunks with null pointers or invalid sample rates are rejected; a truly
empty utterance still reports `empty_audio`. Errors after an earlier chunk abort
the utterance before playback, rather than playing an incomplete response.

Apply from the project root, then rebuild the C++ executable:

```sh
git apply --check ~/Downloads/erm_tts_final_chunk.patch
git apply ~/Downloads/erm_tts_final_chunk.patch
PIPER_PREFIX=/opt/piper rebar3 as tts compile
```

Use your actual Piper SDK prefix. This is a native executable fix; Erlang-only
recompilation does not install it. In a release, rebuild and deploy the release
with its tts profile. In development, restart the TTS child after building:

```erlang
supervisor:terminate_child(erm_sup, erm_tts).
supervisor:restart_child(erm_sup, erm_tts).
erm_tts:status().
```

Wait for ready, then test the phrases separately, allowing each to finish:

```erlang
erm_tts:say("Stopped.").
erm_tts:say("Hello Steven. The voice system is ready.").
```

Expected: the first speaks its entire sentence; the second speaks both sentences.
If the node still exhibits the old result, compare `erm_tts:diagnostics()`'s
binary path with the executable rebuilt/deployed, and ensure the old native
process was restarted.

Verification:

```sh
PIPER_INCLUDE=/opt/piper/include sh apps/erm/test/tts_discovery_isolated/run.sh
```

The updated fake Piper models both completion conventions. The player fixture
captures the WAV, and regression tests inspect exact ordered PCM samples and
RIFF/data sizes. They cover one and two chunks, repeated requests using the same
synthesizer, OK+is_last, legacy empty DONE, null data, invalid sample rates,
empty output and failure after an earlier chunk. Player cancellation is checked
with a held-open player heartbeat, avoiding cross-namespace /proc PID ambiguity.
The old worker reproduced
empty_audio and missing final PCM; the fixed worker passes those checks. These
are native protocol/WAV regression tests, not live voice-quality validation.
