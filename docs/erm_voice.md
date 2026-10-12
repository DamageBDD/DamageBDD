# erm voice commands

This update adds voice actions to the existing Whisper service, MPV owner and
playlist, with ECAI retrieval and a separate small Ollama model for interpretation
and short answers. No change is made to the coding model in ecai_ollama_rag.

## Install

From the DamageBDD repository root, check and apply the supplied patch:

```sh
git apply --check erm_voice_commands.patch
git apply erm_voice_commands.patch
ollama pull qwen3:1.7b
rebar3 compile
rebar3 eunit --module=erm_voice_tests,whisper_trigger_srv
```

The ZIP contains the equivalent source files, example configuration, tests and
this guide. Use the patch or copy the source files, not both. The patch is based
on whisper_trigger_srv(4).erl, erm_sup(10).erl and whisper_trigger_ui(2).erl from
this conversation; check conflicts if your local files have additional changes.
The supplied erm_playlist.hrl is unchanged from your attached record definition.

Merge `config/erm_voice.sys.config.example` into the existing `erm` application
entry. Preserve existing microphone/model/bin and other application settings.
Restart the application/release so sys.config and the new supervisor children
are loaded. Editing sys.config does not update a running VM by itself.
Set `ecai_base_dir` to the existing index used by ecai_ollama_rag; it is deliberately
not guessed. Normal playback and general questions do not require an ECAI index.
Your usual media subsystem and populated playlist must be available for playback.

The defaults enable voice actions when Whisper is enabled and its prerequisites
are present. `{voice, [{enabled, false}]}` disables voice actions while retaining
the existing trigger-handler behaviour. Direct `whisper_trigger_srv:start_link/0`
does not start a router; use normal supervised startup, or explicitly start
`erm_voice:start_link(VoiceOptions)` first when testing outside erm_sup.

## Say these commands

| Spoken command | Route |
| --- | --- |
| Bob, play / start / resume | Resume; if idle, load current/first playlist track |
| Bob, pause | Explicit pause, never a toggle |
| Bob, stop | Stop playback; keep the managed MPV service |
| Bob, next song / previous track | Navigate the persistent playlist |
| Bob, play Wonderwall by Oasis | Search filename-derived title and artist metadata |
| Bob, set volume to 35 | Set volume, restricted to 0–100 |
| Bob, what is playing | Current playlist title/artist |
| Bob, show player / hide player | Existing erm_mpv window |
| Bob, ask why the sky is blue | Short answer from the small Ollama model |
| Bob, ask ecai how the relay bridge works | Existing ECAI retrieval + small-model answer |
| Bob, please pause the music | Schema-constrained model interpretation |
| Bob, cancel | Cancel pending planning; cannot undo an action already dispatched |

Commands in the deterministic grammar do not call Ollama or embed the playlist.
Song lookup is local and deterministic, with no invented paths/URLs/track ids.
Matching searches the playlist already loaded by erm, not the entire filesystem.
All query words must occur in the title/artist; an exact title gets priority.
Equal top scores return an ambiguity result so you can repeat with the artist.
Selecting a track writes a progression M3U in the user's erm cache and loads the
selected track plus the rest of the queue, preserving automatic progression.
No library rescan is triggered by speech.

## Wake and context boundaries

- Unicode NFKC normalization and case folding; exact token-based wake aliases.
- A wake phrase must address the service at the beginning, optionally after
  “hey”, “ok” or “okay”. “I spoke to Bob” and “Bobby” do not wake it.
- Explicit aliases belong in `trigger_phrases`; no fuzzy edit-distance matches.
  A longer multiword wake phrase is less likely to occur in ordinary speech.
- A multiword wake alias split across two records is joined within 1.5 seconds.
- A wake-only record can open capture for the following command record.
- Rolling transcript revisions replace the pending candidate. Overlapping
  fragments are joined. Unrelated non-overlapping fragments cancel capture;
  speak the command in one continuous phrase for best results.
- Execute once after unchanged command text for `settle_ms` (default 1100 ms).
  This is a transcription-stability heuristic, not an acoustic end-of-speech
  detector; pauses and long model decoding intervals can still split speech.
- Capture expires after 8 seconds. An expired partial command is discarded.
- The session closes after one command. There is no un-woken follow-up window
  and no conversation history is carried into the next model request.
- Continuous duplicate redraws keep the previous command locked. A different
  addressed action can start immediately; same-verb revisions are suppressed.
  Repeating the same command requires re-arming (a non-wake record or 6 seconds
  without transcript records) and the 6-second command dedupe window to expire.
- Whisper output must reach the boundary machine *before* logging deduplication.
  The existing trigger cooldown remains for the legacy trigger handler; the
  nested voice timing settings separately govern command execution.
- Restarting/stopping listening, changing input or changing trigger phrases
  clears unfinished capture and cancels pending model planning.

No acoustic speaker verification or echo cancellation is added. Spoken media can
still contain a correctly addressed wake phrase. The UI displays text responses;
this update does not synthesize speech or feed responses back into the microphone.

## Model and ECAI routing

Default: `qwen3:1.7b` (Ollama's Q4_K_M tag is approximately 1.4 GB on disk).
Requests use `think=false`, `temperature=0`, `num_ctx=4096`, bounded output and
`keep_alive="10m"`. First use still has model-load latency. This model choice has
not been benchmarked on your hardware. For a smaller option, set `qwen3:0.6b` and
pull that tag, then check intent accuracy against your own phrases.

Ambiguous phrasing gets a JSON-schema classification request. Only allowlisted
actions, short string arguments and volume values 0–100 pass validation. Model
output is never converted to atoms, shell commands or arbitrary module names.
Questions use a fresh two-message request. Explicit ECAI questions call the actual
`ecai_ollama_rag:retrieve_sources/3` API, request three sources, clip each source's
text to 1400 characters, and use the same small model to answer. Retrieval has
its own deadline and may use your existing embedding model internally. Missing
index, insufficient sources and backend failures are surfaced rather than
silently substituted with ungrounded answers. Source titles/CIDs are retained.

Planning and execution run in monitored, linked workers. Only one job is active;
new work is rejected as busy rather than queued for stale execution. Stop/pause
can cancel an active planning request. Execution already sent to another server
cannot be rolled back; an action timeout is reported as uncertain and is never
automatically retried. UI controls continue to work independently.

## Other actions

Register application-owned handlers in the nested voice proplist:

```erlang
{actions, [
  {<<"lights_on">>, "Turn on the office lights", {my_home_actions, lights_on}}
]}
```

Implement `my_home_actions:lights_on(QueryBinary, ContextMap)`. The context is
`#{source => voice, action => <<"lights_on">>}`. Return `ok`, `{ok, Result}` or
`{error, Reason}`. Names must be unique lowercase ASCII identifiers and cannot
replace built-in actions. Only handlers you configure are callable. Model
classification selects the name; Erlang looks up the trusted MFA. Generic
questions and retrieved source text cannot themselves execute returned code.

## Observe and test

The Whisper dashboard now displays the last command, progress and result/answer.
Results are also logged. From the shell:

```erlang
erm_voice:status().
erm_voice:command("pause"). % Explicit typed command: bypasses wake capture.
erm_voice:reset().          % Clear capture and cancel pending planning.
whisper_trigger_srv:matches_trigger("Hey Bob, next song").
```

`matches_trigger/1` checks addressed wake detection; it does not execute actions.
The legacy custom `trigger_handler` remains supported and is independent of
voice dispatch. Remove any old handler that already controls media to avoid
issuing duplicate commands via two systems.

Offline verification (fresh VM, no microphone, GUI, model or real media):

```sh
sh verification/voice/run.sh
```

Fixtures are outside `apps/` so normal builds do not compile or load them. They
replace HTTP/codec/MPV/playlist/ECAI APIs only inside the isolated smoke-test VM.
The codec fixture is not JSON: these tests verify the request structure and
control flow, not the real JSX implementation or an Ollama server.

Verification on Erlang/OTP 25: all changed modules compiled; 52 EUnit tests passed;
the isolated integration smoke passed, covering direct controls, song selection,
queue progression, redraw suppression, model request fields, output validation,
isolated answers, bounded ECAI source context, cancellation and planning timeout.
Two existing unused-function warnings remain in erm_sup (gtknode4_specs/0 and
lens_specs/0). Live Whisper/SDL, MPV IPC, GTK rendering, ECAI index and Ollama
behaviour have not been exercised in this workspace.

References checked 2026-09-30:
- https://ollama.com/library/qwen3:1.7b
- https://docs.ollama.com/api/chat
