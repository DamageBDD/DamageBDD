# Video Studio in the ECAI dashboard

**Source:** `apps/ecai` from `latest-ecai.tar.gz`, 11 October 2026.

Open **`/dashboard#video`** (select *Video Studio* in the sidebar). The panel
is always visible, even if the optional Fastpath sidecar has not been deployed.

## Required deployment changes

Apply **both** patches from the video dashboard delivery:

- `ecai-video-dashboard-ecai.patch` against the DamageBDD repository (adds
  the integrated dashboard and `ecai_video_dashboard_http` route).
- `ecai-video-dashboard-fastpath.patch` against the previous Fastpath sidecar
  (`apps/ecai_video_fastpath`). The legacy service understands only a single
  shared tenant API token and cannot safely serve multiple dashboard accounts.

The sidecar service is **not** included in the uploaded `latest-ecai.tar.gz`;
it was delivered earlier as `ecai-video-fastpath.tar.gz`. Do not deploy only
the dashboard patch and expect the existing bridge token to work.

Configure the same strong shared secret on **both** the ECAI Erlang node and
Fastpath sidecar:

```sh
python -c 'import secrets; print(secrets.token_hex(32))'
# Copy that value to BOTH process environments:
export ECAI_VIDEO_BRIDGE_SECRET='the-generated-value'
# ECAI node only (default shown):
export ECAI_VIDEO_URL=http://127.0.0.1:9011
```

Start the sidecar with its existing `compose.yaml` and `.env`, which should
include `ECAI_VIDEO_BRIDGE_SECRET`. For a Dockerised ECAI node, `127.0.0.1`
refers to the ECAI container itself; use a private HTTPS endpoint or arrange
the networking so the configured endpoint is actually reachable. **Never**
publish an unauthenticated HTTP sidecar to the internet. Use an HTTPS URL
with verified certificates across hosts.

Optionally enable customer-managed provider configuration on the sidecar:

```sh
# python -c 'from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())'
ECAI_VIDEO_FERNET_KEY='a-generated-Fernet-key'
ECAI_VIDEO_ALLOWED_CONNECT_HOSTS='["queue.fal.run", "fal.media"]'
```

Approved connection hosts must match the actual provider endpoint; download
hosts are separately checked. Model billing and data-use terms remain the
customer/operator's responsibility. The built-in `demo` backend creates a
synthetic clip without calling a generative video model.

## Dashboard features

1. Sign in with a **managed DamageBDD account** (wallet-only mode is
   deliberately excluded from video management).
2. Create/select a project and connect or choose an operator-installed
   provider. Provider credentials are stored by Fastpath, encrypted when
   configured; no credentials appear in the dashboard bundle.
3. Generate a video asynchronously, or import a local MP4 of up to 25 MiB.
4. Inspect a persisted job on page reload, with explicit acknowledgement
   before retrying ambiguous submissions that might generate duplicate fees.
5. Select an asset revision, request a bounded preview/download, and create
   metadata-only, caption or trim revisions without another provider call.
6. Verify the signature, SHA-256 media digest and lineage. Optionally obtain
   an *NFT metadata draft* after publishing content independently to IPFS.

The dashboard's `GET /ecai/video/status` reports configuration only. An enabled
status is not proof that the sidecar is online; the UI reports service health
after authenticated API calls.

## Authentication boundary

`ecai_video_dashboard_http` never accepts an arbitrary upstream URL from the
browser. It enforces fixed paths and lowercase hexadecimal object IDs, and
requires managed identity resolved from DamageBDD. **Mutating operations require
an explicit verified bearer token**; no ambient cookie alone can submit a
billable job. Each account receives an independent sidecar tenant based on a
hash of its authenticated public account identity.

For each upstream request, the Erlang node signs a 60-second-lived
`bridge1.<tenant>.<unix_timestamp>.<hmac_sha256>` token covering the tenant,
request method and fixed path. Fastpath checks the signature and clock window.
Keep the secret confidential; an operator with that secret can impersonate all
bridge tenants. Static Fastpath API keys remain separate for direct API clients.

This integration does not contain a billing/quota service, independent
cryptographic verification client, CDN, full media streaming, live IPFS
publication or chain minting. Video preview and upload are bounded at 25 MiB;
the initial synchronous Erlang proxy buffers upstream responses and should be
replaced by a streaming gateway or private object-storage delivery path before
handling large production video assets.

## Validation

From the DamageBDD repository root:

```sh
# ECAI only; source/layout check without Erlang or DamageBDD runtime:
python apps/ecai/test/test_video_dashboard_contract.py
node --check apps/ecai/priv/static/js/ecai-video.js
node --check apps/ecai/priv/static/js/ecai-console.js

# Real browser/DOM test (requires a Chromium installation that permits local URLs):
python apps/ecai/test/test_video_dashboard_browser.py

# Full runtime checks need the complete DamageBDD checkout and OTP toolchain:
rebar3 eunit --app ecai
```

From `apps/ecai_video_fastpath`:

```sh
PYTHONPATH=. pytest -q
```

The ECAI archive alone cannot compile because it relies on the rest of the
DamageBDD workspace. Browser tests may skip when Chromium is deliberately
locked down by `URLBlocklist: ["*"]` enterprise policy.


### Video Studio template mount (October 2026 fix)

The main dashboard template includes the Video Studio controls directly,
including `#videoRefresh` and `#videoProjectForm`. Previously it relied on a
`{{{video_studio}}}` interpolation supplied by `ecai_dashboard.erl`; when the
BEAM module or template rendering context was out of date, the panel was blank
while its JavaScript attempted to attach listeners to missing elements.

`ecai_video.mustache` remains a matching source fragment for editing; the
contract test asserts its content is present in `ecai_console.mustache`.
Update both together. The controller now presents a dashboard diagnostic if the
mount is unexpectedly incomplete rather than terminating all dashboard setup.
Cache-busted `video-studio-v3` URLs avoid executing a stale Video Studio module.

To validate the served page from an operator machine:

```js
console.log(document.querySelector('[data-panel="video"]'));
console.log(document.getElementById('videoRefresh'));
```

Both must be non-null on `/dashboard`, even before selecting the Video tab.
Remember that ECAI's Erlang route module still requires build/reload when
changing API routing, independently of this template-only fix.
