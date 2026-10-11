# ECAI Video Fastpath 0.1 — Bring Your Own Video Backend

An installable, customer-facing proof of value for ECAI's **reusable, signed video asset structure**, not another generic video generation wrapper.

**Immediate path:** import a customer's existing MP4 -> record its content identity -> change only metadata or render an isolated caption/trim locally -> reuse upstream clips -> verify signed lineage -> download media and signed manifest. A customer can optionally connect their own HTTP video backend or fal.ai queue key, without setting up a GPU. NFT export is **draft-only** in this POC.

## What runs today

- FastAPI sidecar with secure-ish pilot access via operator-issued Bearer workspace keys, isolated SQLite tenants, and a compact `/studio` web UI.
- Original MP4 upload; content-addressed storage by SHA-256, validated with `ffprobe`.
- Metadata revision: **exact MP4 reuse** (no provider call and no re-encode).
- Caption/trim: local FFmpeg processing; **no provider regeneration**; new content-addressed object and signed lineage.
- SHA-256-linked parent manifests and secp256k1 ECDSA signatures. Offline verifier with a *trusted*, pinned public-key fingerprint.
- Graph/lineage, simple user-supplied metadata search, per-project provider-call/reuse counters.
- Customer-supplied video backend: synchronous HTTP JSON returning a video URL; fal queue submit/status/result; synthetic demo backend.
- Encrypted at-rest per-tenant backend keys with operator-approved outbound domains; persist/poll jobs across restart, and avoid silent double submission after ambiguous crashes.
- Draft NFT metadata for later `damage_ipfs` + `ecai_nft` integration. **No claim of successful pin/mint, paid checkout, or rights verification.**
- Optional Erlang caller `apps/ecai/src/ecai_video_fastpath.erl` (installable alongside `apps/ecai`), with no changes to existing Cowboy routes or supervisor.

### One-command container launch

```bash
cd apps/ecai_video_fastpath
cp .env.example .env
# Edit .env and replace the example ECAI_VIDEO_KEYS value with a unique long key.
docker compose up --build -d
# Open http://127.0.0.1:9011/studio
```

Published port is loopback-only by default. The key must be entered into the studio page; the browser does not write it to local or session storage. For public customers, put a **TLS reverse proxy** in front, use secret management, abuse protection and a billing/entitlement layer. The demo backend generates synthetic moving test footage; it is *not* an AI model.

Without Docker (Python 3.11+, FFmpeg/ffprobe required):

```bash
cd apps/ecai_video_fastpath
python -m venv .venv && . .venv/bin/activate
pip install -e '.[test]'
export ECAI_VIDEO_KEYS='{"customer1":"REPLACE_WITH_AN_ACTUAL_RANDOM_32_CHAR_TOKEN"}'
export ECAI_VIDEO_DATA=./data
uvicorn ecai_video_fastpath.api:app --host 127.0.0.1 --port 9011 --workers 1
```

To generate a strong key: `python -c 'import secrets; print(secrets.token_urlsafe(32))'`.

### Run the evidence loop

In another terminal:

```bash
cd apps/ecai_video_fastpath
export ECAI_VIDEO_TOKEN='the_key_you_configured_for_customer1'
python scripts/quickstart.py
# or visit /studio: Connect -> Create Project -> Upload -> Metadata -> Verify
python -m pytest -q
```

The quickstart creates an MP4, imports it, builds two variants, verifies a signed manifest, and displays lineage plus the avoided-provider-call counters. All without fal, Runway, GPU, IPFS or wallet access.

## Customer connects their existing video backend

Self-service connections require an encryption key and an explicit allowlist of *real* HTTPS provider hosts in the service environment:

```bash
python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'
# In .env (substitute the generated key):
ECAI_VIDEO_FERNET_KEY=GENERATED_FERNET_KEY
ECAI_VIDEO_ALLOWED_CONNECT_HOSTS=["queue.fal.run","fal.media","v3.fal.media"]
```

The Studio exposes **Connect your own video backend** after these are configured. Customers choose a connection ID, backend kind (`http_sync` or `fal_queue`), approved HTTPS URL, API key, result URL field (for example `video.url`), allowlisted media CDN hosts, and JSON defaults (such as `{"duration":"5","aspect_ratio":"16:9"}`). The key is encrypted in SQLite and is not shown in GET responses. Only operator-approved domains may be contacted; TLS is mandatory outside the explicit test-only private-network setting. Back up both the data volume and the Fernet key; losing either can make provider accounts unusable.

A *generic HTTP synchronous backend* receives a POST like:

```json
{"prompt":"Cinematic product shot", "duration":"5"}
```

Its JSON response must contain a configured URL field, e.g. `{"video_url":"https://cdn.approved.example/result.mp4"}`. The service downloads and validates the actual MP4 before signing it. The generation endpoint takes only a registered `backend_id`, not an arbitrary URL. Advanced per-request parameters are denied unless explicitly included in that backend's `allowed_parameters` list. This prevents client requests from silently overriding cost-affecting settings in a shared operator connection.

For **fal queue**, configure a URL such as `https://queue.fal.run/fal-ai/kling-video/v3/pro/text-to-video`, authorization `Key`, a provider token, the correct `video.url` result field, and the exact CDN hostnames returned by the actual model. The adapter submits the request and polls the `requests/{id}/status` endpoint. Confirm the provider's current schema and commercial terms before accepting paid traffic.

For an **operator-managed** backend (no customer key storage) use `ECAI_VIDEO_BACKENDS` JSON. Example:

```json
{
  "demo": {"kind": "demo"},
  "studio": {
    "kind": "http_sync",
    "label": "Our video model",
    "url": "https://generation.example.com/v1/generate",
    "auth_env": "VIDEO_PROVIDER_KEY",
    "auth_scheme": "Bearer",
    "output_path": "output.video.url",
    "download_hosts": ["cdn.example.com"],
    "defaults": {"duration": "5"},
    "allowed_parameters": ["aspect_ratio"]
  }
}
```

The config is server-side only; `VIDEO_PROVIDER_KEY` must be supplied separately as an environment secret. Avoid untrusted public URLs and never configure broad wildcard domain allowances.

### API workflow (curl)

```bash
export BASE=http://127.0.0.1:9011
export TOKEN='your_workspace_key'

# Create a project; save id from returned JSON.
curl -sS -X POST "$BASE/v1/projects" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Customer Campaign","license":"customer-owned"}'

# Import an actual MP4 (save version.id from response).
curl -sS -X POST "$BASE/v1/projects/PROJECT_ID/assets" \
  -H "Authorization: Bearer $TOKEN" -F 'file=@clip.mp4'

# Metadata edit: exact same video bytes, new signed version.
curl -sS -X POST "$BASE/v1/projects/PROJECT_ID/versions" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"parent_version_id":"PARENT_VERSION_ID","operation":"metadata","options":{"note":"AU pricing"}}'

# Verify and export proof/media:
curl -H "Authorization: Bearer $TOKEN" "$BASE/v1/versions/VERSION_ID/verify"
curl -H "Authorization: Bearer $TOKEN" "$BASE/v1/versions/VERSION_ID/manifest" > manifest.json
curl -H "Authorization: Bearer $TOKEN" "$BASE/v1/versions/VERSION_ID/video" -o clip.mp4
# Get fingerprint from a trusted operator channel; /v1/public-key is helpful but not sufficient alone.
python scripts/verify_export.py manifest.json clip.mp4 TRUSTED_SIGNER_FINGERPRINT_SHA256
```

API docs: `http://127.0.0.1:9011/docs`. Per-project `/value` reports real *counters*, not invented dollar savings.

## Erlang/DamageBDD integration (minimal, opt-in)

The patch includes `apps/ecai/src/ecai_video_fastpath.erl`. It calls the sidecar directly from Erlang without adding new Cowboy endpoints or breaking ECAI auth. In a trusted Erlang node shell:

```erlang
%% OS variables ECAI_VIDEO_URL and ECAI_VIDEO_TOKEN set for the BEAM process.
{ok, Project} = ecai_video_fastpath:create_project(<<"Ad">>, <<"customer-owned">>, []).
ProjectId = maps:get(<<"id">>, Project).
{ok, Job} = ecai_video_fastpath:generate(ProjectId, <<"demo">>, <<"Test pattern">>).
{ok, Status} = ecai_video_fastpath:job(maps:get(<<"id">>, Job)).
%% When completed:
%% ecai_video_fastpath:verify(maps:get(<<"version_id">>, Status)).
```

Erlang bridge `upload_mp4/2` is intentionally capped at 25MB in-memory. Use the Studio or HTTP upload for larger clips. The bridge is **not** exposed to unauthenticated Cowboy clients. Production ECAI dashboard integration should use `damage_http:is_authorized`, pass the authenticated tenant ID, and map it securely to a backend workspace token. Never expose a server-wide workspace token to arbitrary frontends.

## Recoverability, verification, and hard limits

- SQLite WAL persists generated videos, jobs, versions and signed metadata on a persistent volume. A restarted worker resumes known remote requests. If it died during *submission before storing the remote ID*, the job enters `needs_review`, requiring explicit retry (provider may have billed). This is more honest than promising exactly-once API charges.
- Signed lineage links to parent **manifest hashes**; the verifier checks the chain and the local MP4 content hash. It does not prove human authorship, image semantics, source rights, or that a remote media CDN/IPFS gateway currently serves identical bytes.
- ECDSA secp256k1 signs **canonical structured data**; elliptic-curve cryptography does not infer the meaning of footage. This module can later publish signed triples into ECAI's global index, but that integration is not falsely marked as complete.
- NFT endpoint prepares metadata with supplied IPFS CIDs; it does **not** pin the content, verify the CID against remote bytes, mint an NFT, transfer rights, or take payment. Those are explicit gates for a production release.
- MVP deployment: **one Uvicorn process**; one active generation per project; individual upload <= configured limit; MP4 only; outputs <= max duration. Real commercial hosting also needs customer billing, quotas, malware scanning, legal consent, observability, worker isolation, background polling scaling, and structured audit retention.
- Text overlay requires FFmpeg compiled with libx264 and drawtext and an installed readable font. Don't put arbitrary Python or Blender scripts from customers into this service.
- Signed manifests include an operator public-key fingerprint. Consumers must acquire the trusted fingerprint independently. The signature is integrity/authenticity evidence, not copyright or AI provenance certification.

## Acceptance tests

`python -m pytest -q` runs real FFmpeg/ffprobe integration tests for: signed import, exact byte reuse, caption/trim generation, immutable revisions, cross-tenant authorization, content tampering detection, restart-safe jobs, a fake customer HTTP provider, and encrypted customer-provided backend credentials. `fastpath.feature` documents the BDD acceptance contract but is not executed by `pytest`.

Tested here in Python with FastAPI, cryptography, httpx and installed FFmpeg. The Erlang bridge has not been compiled in a matching DamageBDD checkout in this environment; run `rebar3 compile` and `rebar3 eunit` in your checkout after applying the patch.

## Suggested first paid pilot

Charge for **verifiable campaign variations and controlled updates**, not the provider-generated clip. For example: a monthly creative workspace fee and a per-delivered-version fee, with upstream video usage billed separately or charged through a clearly disclosed allowance. Sell to an agency already generating social ads with Runway, Kling or Veo; show exact media reuse, audit trails, and faster local revisions before adding NFT minting or marketplace settlement.

## Embed inside the ECAI dashboard (managed-account mode)

The dashboard uses `/ecai/video/*` same-origin routes via a Cowboy bridge. It
never embeds the sidecar API keys or customer provider credentials in its HTML.
To enable separate storage for every authenticated DamageBDD managed account:

1. Generate a strong `ECAI_VIDEO_BRIDGE_SECRET` (at least 32 characters) and
   configure the **same value** in the Fastpath sidecar and the ECAI node.
2. Set `ECAI_VIDEO_URL=http://127.0.0.1:9011` (or an HTTPS endpoint with
   validated certificate) for the ECAI node. The dashboard bridge is
   intentionally disabled until these are configured.
3. Deploy the updated Fastpath service code. Static `ECAI_VIDEO_KEYS` continue
   to authenticate direct API clients; the dashboard uses short-lived HMAC
   credentials scoped to the validated account, HTTP method and endpoint path.
4. Sign in at `/dashboard#video` with a managed email session. Wallet-only
   sessions are not authorized for video management.

A different managed account receives an independent tenant and cannot read
previous users' video projects. Sharing a bridge secret between untrusted nodes
would allow either node to impersonate accounts: keep it secret, rotate it if
compromised, and keep the sidecar port private.

The initial dashboard caps uploads and previews at 25 MiB and supports
metadata, caption and trim revisions; it is not a public video CDN.
Exporting NFT metadata is **draft only**, not IPFS publication or minting.
