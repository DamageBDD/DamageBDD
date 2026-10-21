# Voice notes in the Nosternity composer

This patch is based on `latest-nosternity.tar(6).gz` (21 October 2026), which
already includes the dashboard, branding, theme and storage integration. Apply
it from the DamageBDD repository root instead of the earlier voice-note patch.
It also adds the ECAI voice-note adapter and tests under `apps/ecai`; existing
ECAI WAV and Ollama modules are reused. It uses the current Nostr, Lightning and
DamageBDD browser session service; publishing still needs a Nostr signer.

## Recording and review

Choose **Write a note**, then hold **Hold to talk**, or use **Tap to record**.
Space/Enter on the hold button records until key release. The tap button also
supports keyboard and assistive activation. Recording stops on release, after
1.2 seconds below the microphone level threshold once speech is detected, or
at the short-clip limit. Six seconds without speech discards the clip.

The default cap is 30 seconds. Capture stops 300 ms early to leave room for
codec padding and timer jitter; the server independently enforces the actual
decoded duration. The level gate is an RMS heuristic, not a speech classifier:
background noise can keep it open. Use release/Stop in noisy surroundings.

The browser requests mono audio with echo cancellation and noise suppression.
MediaRecorder prefers WebM/Opus, then Ogg/Opus, then MP4/AAC, requesting 24 kbit/s.
The browser may choose a different bitrate, so the client and server also cap
the actual upload at 2 MiB. No base64 expansion or third-party codec download is
needed. A browser without a supported recorder keeps ordinary text entry usable.

After recording, play the clip, edit the transcript, and choose **Insert into
note**. Existing note text is preserved. **Sign & publish** remains a separate
action and signs only the reviewed text as a kind-1 note. This does not publish
audio attachments, voiceprints or speaker identities.

## Transcription selection

| Mode | Behavior |
| --- | --- |
| On-device when available, otherwise ECAI | Checks `SpeechRecognition.available` for the selected language and an installed dictation pack, and requires `processLocally`. Otherwise uses ECAI. A failed or early-ended browser recognizer falls back to the full recorded clip. |
| ECAI / Whisper | Sends the compressed clip to this node's authenticated endpoint. |
| Browser speech service | Explicitly uses the browser's SpeechRecognition service, which may transmit audio externally. If recognition fails, the clip falls back to ECAI. |

On-device support is experimental and differs by browser/language. This UI
does not automatically install language packs or silently switch automatic
mode to a remote browser provider. English, Malayalam, Tamil, Hindi, Spanish,
German, French and Japanese are offered. Use a multilingual Whisper model for
non-English clips; the language choice is sent without requesting translation.

The existing `ecai_voice` module analyzes speakers and does not transcribe.
`ecai_voice_notes` reuses `ecai_voice_wav` to validate/encode 16 kHz mono PCM16,
then calls the local whisper.cpp `/inference` API. It can share the daemon that
erm manages: point `whisper_port` at that daemon. It does not capture audio from
the server microphone or alter erm's wake-word/speaker-enrollment state.

Ollama is an optional second text-processing pass through the existing
`ecai_ollama_client`. Enable it in configuration and select **Polish ECAI
transcript with Ollama** per recording. It corrects punctuation/spacing,
preserves the raw ASR transcript for comparison, and returns the original if
cleanup fails. It has no tools or command-dispatch path. Review its output:
the prompt does not guarantee that a generative model preserves every word.
Successful browser transcription stays in the browser and skips this pass.
The implementation does not assume that a text-only Ollama model accepts audio.

## Server setup

1. Install FFmpeg with WebM/Opus, Ogg/Opus and MP4/AAC decoding. Run it under the
   existing unprivileged application service account.
2. Start a loopback whisper.cpp server with your installed model, or reuse erm's
   existing server. For example:

   ```sh
   whisper-server --host 127.0.0.1 --port 8080 --model /path/to/ggml-base.bin
   ```

3. Merge `voice-notes.sys.config.example` into the umbrella's **existing**
   `ecai` entry. Server transcription defaults to disabled. The default backend
   is `127.0.0.1:8080/inference`; override its port to match the running daemon.
   Ollama cleanup defaults off. Set an already installed text model before
   enabling it; `qwen3:0.6b` in the example is a configurable example, not a model
   downloaded or validated by this patch.
4. Rebuild/restart the release. Serve the dashboard over HTTPS (localhost works
   for development), and allow at least 65 seconds for the reverse-proxy request
   timeout and 2 MiB for uploads. Keep `browser_auth_origin` set to the dashboard
   origin. Do not expose Whisper or Ollama directly to the browser.

Only loopback provider hosts are accepted. The request cannot override provider
hosts, paths, model names or commands. `voice_notes` is a validated Erlang map;
unknown keys fail closed. `max_duration_ms` accepts 1,000–30,000 and
`max_audio_bytes` accepts 32,768–2,097,152. This feature changes no system-wide
voice or LLM defaults.

## HTTP API

Both routes require a live Nosternity session cookie and `X-Nosternity-Auth: 1`.
POST additionally requires the configured same-origin `Origin` header, as do
the existing dashboard mutations. Nostr, Lightning and bridged DamageBDD
sessions all work; a raw wallet address or public key is not authentication.

| Endpoint | Request | Result |
| --- | --- | --- |
| `GET /api/nosternity/voice/options` | Authenticated GET | Public enable flags and caps; no internal provider settings. |
| `POST /api/nosternity/voice/transcribe` | Raw audio body; `Content-Type: audio/webm`, `audio/ogg`, `audio/mp4`, or strict 16 kHz PCM WAV. `X-Voice-Language: en` (2–3 lowercase letters), `X-Voice-Cleanup: 0` or `1`. | `text`, `raw_text`, `provider`, `duration_ms`, `cleanup_applied`, and an optional cleanup warning. |

The handler checks origin/session before reading audio, bounds both declared
and chunked uploads, applies the existing per-identity attempt limiter, and
permits one decode/transcription/cleanup job per node with no job queue. Busy
requests return 429 and keep the browser clip available for retry. Other useful
statuses are 401 (expired session), 413 (bytes), 415 (format), 422 (bad/silent/
overlong audio), 503 (disabled/unavailable), and 504 (transcription timeout).
Provider error bodies are not returned. Session validity is rechecked before
returning inference results.

FFmpeg runs without a shell, with a fixed demuxer, no network protocols, bounded
PCM output and a 10-second deadline. Whisper has a 25-second response deadline
and a 64 KiB response cap. Ollama gets a 15-second request timeout and a 1,024-token
output budget. Connection setup is also bounded.

Clips, transcripts and object URLs are held in tab memory. Closing the composer,
discarding, or hiding the tab during an operation stops capture/aborts the
browser request. An accepted server operation may finish after client abort;
it remains bounded. The server does not index, publish or retain audio as an
account artifact. Compressed uploads use private temporary directories (0700),
removed on normal success, error and timeout. Abrupt VM/OS termination can leave
temporary files: use your service's private temporary directory/lifecycle cleanup.
Whisper/Ollama operator logging policies remain the operator's responsibility.

## Validation

From the repository root, after building the normal project dependencies:

```sh
bash apps/nosternity/test/voice_notes/run.sh
cd apps/nosternity/assets
npm ci
npm test
```

The suite exercises real WebM/Ogg/AAC decoding through FFmpeg, ECAI WAV checking,
real Nostr proof/session creation, Cowboy/Gun requests, upload limits, origin
rejection, concurrent inference rejection, mid-request logout, and the actual
Ollama text client against a loopback model fixture. Frontend tests cover silence
detection, codec selection, local/remote recognition routing, permission races,
retry, cancellation, keyboard controls and review-before-insert behavior.

The 20 October rebase passed 18 browser tests, 6 voice integration tests and
14 branding tests against the supplied Nosternity archive. Voice integration
used the original patch's ECAI client with the available DamageBDD dashboard
authentication code. Keep `ecai_ollama_client` and `damage_gun` from compatible
versions: newer clients pass `max_response_bytes`, which older HTTP wrappers
reject. That mismatch leaves the raw transcript intact but disables successful
Ollama cleanup. A full build of your current umbrella was not available here.

The 21 October archive has identical source contents and file permissions to
the 20 October baseline. The dated `nosternity-voice-notes-20261021.patch` was
verified with `git apply --check` and a full apply against a fresh extraction
of that archive, including the executable dashboard test runner.

Before deployment, smoke-test a real microphone on your target Chromium,
Firefox and Safari/mobile versions and transcribe speech with the actual model.
Model accuracy and acoustic performance are not established by synthetic codec
fixtures or mocked browser recognition.

Protocol references:

- [MDN on-device recognition availability](https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition/available_static)
- [MDN MediaRecorder codec support](https://developer.mozilla.org/en-US/docs/Web/API/MediaRecorder/isTypeSupported_static)
- [whisper.cpp server API](https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/README.md)
- [Ollama text generation API](https://docs.ollama.com/api/generate)
