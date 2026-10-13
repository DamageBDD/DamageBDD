# Erlang-managed model pulls

Incremental to `erm_tts_discovery.patch`. The new `erm_model_pull` gen_server owns
one asynchronous worker at a time. `erm_tts:child_specs/0` starts it before TTS
when TTS is enabled. Downloads use OTP `httpc`, `ssl`, `public_key` and `crypto`;
no Python, external downloader, or separate daemon is required. The DamageBDD
release already starts inets/ssl/crypto; the transport also ensures its OTP
applications are started on demand.

## Enable

Merge `config/sys.config.model_pull.fragment.config` into the existing `erm`
application configuration. Create a cache directory writable by the service
user. Keep any binary/player/eSpeak overrides needed for your Piper installation.
For example:

```erlang
{model_pull, [
    {cache_dir, "/var/lib/damage/models"},
    {timeout_ms, 600000}
]},
{tts, [
    {enabled, true},
    {voice, lessac_low},
    {auto_pull, true}
]}
```

Recompile and restart the application/node to install the changed supervisor
child specifications. For a build/release that includes the native Piper port:

```sh
PIPER_PREFIX=/opt/piper rebar3 as tts compile
# PIPER_PREFIX=/opt/piper rebar3 as prod,tts release
```

Use the actual SDK prefix. This pipeline installs voice assets only; it does not
install libpiper, the native port, mpv or eSpeak data.

If no explicit model or nonempty `PIPER_MODEL` environment setting is present,
TTS defaults to `voice = lessac_low` and `auto_pull = true`. Setting `auto_pull`
to false restores local-files-only behaviour. Explicit model paths bypass the
pipeline; an explicit JSON override retains precedence. To adopt managed files,
remove the old model/config overrides. Configuration changes need an application
restart (ordinary supervisor restart_child reuses its existing start arguments).

The default cache root is `filename:basedir(user_cache, "erm/models")`, resolved
under the service user's environment, unless `cache_dir` is set. Use an absolute
cache path dedicated to ONE node/VM. The in-process single-flight guarantee does
not coordinate other BEAM instances or hosts; do not share a cache directory
between running nodes. There is no operating-system lock service in this version.

## Workflow and commands

```erlang
erm_model_pull:ensure(lessac_low).
%% {pending, Progress} on first use, {ok, Paths} when verified and ready.
erm_model_pull:status().
erm_tts:diagnostics().
erm_tts:status().
erm_tts:say("test").

%% After fixing a failed network/filesystem request:
erm_model_pull:retry(lessac_low).
%% Cancel the active download:
erm_model_pull:cancel().
```

`ensure/1` returns immediately. Calls for the same active model share the worker;
a different model returns `{error,busy}` until it finishes. Model identifiers must
exist in the configured manifest. Failed pulls retain the failure and require an
explicit `retry/1`; TTS's five-second reconnect does not start a download storm.
A service restart also permits a new attempt. Retries restart incomplete files;
HTTP Range resume and automatic backoff are not implemented.

Status reports checking/downloading/installing/ready/failed. While downloading,
it includes the current filename, cumulative bytes and total bytes. Progress is
updated at roughly 1 MiB intervals and file completion. TTS polls readiness on its
existing five-second reconnect loop; it becomes ready after the files AND native
Piper backend are available. `say/1` returns not_ready while downloading and does
not queue obsolete speech. Model log events use domain `[erm,tts,models]`.

Each file streams to a unique staging directory. Size must exactly match the
manifest, with an early maximum-size check, and SHA-256 must match. The complete
model, JSON and model card are rechecked and published by renaming the directory
on the same filesystem. Individual files are never exposed as a ready voice.
A replacement for an invalid cache is fully verified before the old directory
is quarantined and replaced. A failed pull leaves the existing directory intact.

A node restart or explicit retry rehashes cached files; a valid cache needs no
network. Repeated ready lookups check existence and size without rehashing the
whole model. Treat the cache as immutable; use retry if external tampering or
corruption is suspected. Valid cached paths are named by a manifest digest, so
changed revisions cannot silently reuse different assets. Old valid revisions
are retained; there is no automatic cache eviction.

Cancellation and deadlines terminate the worker, cancel its outstanding HTTP
request through a monitor, and clean staging. Abrupt VM termination can leave
staging files; the next pull of that manifest removes those staging directories.
Cancellation racing a completed publish can leave a fully verified cached copy,
but never publishes a partial model. Directory publication is atomic for process
crashes; this does not claim full filesystem durability through power loss.

HTTPS uses certificate-chain and hostname verification with system CA roots.
Redirects are bounded, must remain HTTPS, and cannot add URL credentials. Final
content is still verified against pinned digests. Signed redirect URLs are not
logged. There is no HTTP proxy configuration in this initial transport; the
service needs direct DNS/HTTPS access and up-to-date CA roots.

## Manifest

The bundled `lessac_low` voice is pinned to Piper voices revision
`c10ece1aade47bb51c153c893d14e5bf8e5b7117`:

* `en_US-lessac-low.onnx` (63,201,294 bytes)
* `en_US-lessac-low.onnx.json` (4,882 bytes)
* `MODEL_CARD` (345 bytes, retained alongside the voice)

Model SHA-256 comes from the repository's LFS metadata. JSON and model-card
SHA-256 values were computed from the pinned files. Exact URLs/digests are in
`erm_model_catalog.erl`; no mutable `main` URL is used at runtime. Upstream:
https://huggingface.co/rhasspy/piper-voices/tree/c10ece1aade47bb51c153c893d14e5bf8e5b7117/en/en_US/lessac/low

Additional operator-reviewed manifests can be supplied as the `manifests` map
inside `model_pull`. Each identifier maps to `#{files => [FileSpec, ...]}` and each
file needs `role` (atom), `name` (safe basename), `url` (HTTPS string), `bytes`
(exact positive integer) and `sha256` (64 lowercase hex characters). Roles and
names must be unique. For TTS, model/config roles are required. Supply immutable
revision URLs and trusted checksums; voice commands/LLM output must not create
manifests. The API supports other model assets, but automatic Whisper/VAD/speaker
model configuration is not wired in by this patch.

## Verification

```sh
sh apps/erm/test/model_pull_isolated/run.sh
PIPER_INCLUDE=/opt/piper/include sh apps/erm/test/tts_discovery_isolated/run.sh
```

The pull suite uses real OTP HTTPS against a local TLS server with a temporary
test CA. It covers duplicate requests, redirects, checksum/size/HTTP failures,
streaming, cancellation, deadlines, offline cache reuse, corrupted-cache repair,
process-crash staging recovery and TTS startup using a framed native-port fixture.
It requires OTP inets/ssl/crypto/EUnit, a C compiler and OpenSSL for test fixtures.
Existing TTS lifecycle tests use a mock Piper library, not a live audio device.

The development environment blocked direct DNS resolution of Hugging Face
(`nxdomain`), so a complete live upstream model pull could not be verified here.
The source metadata/pinned JSON and model card were retrieved separately; the
actual runtime HTTPS workflow was verified against the local test server.
