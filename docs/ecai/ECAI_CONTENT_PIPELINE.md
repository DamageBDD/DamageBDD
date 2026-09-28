# ECAI learned-code publication pipeline

This subsystem turns the persisted state produced by `ecai_codebase_learner` into grounded publication artifacts. It does not treat the Ollama model as memory. The evidence object is derived from the ECAI learning snapshot and DETS-backed knowledge state, and every publication job is keyed by the learned snapshot identity plus scope and prompt version.

## Flow

```text
source / BEAM / Git
        |
        v
ecai_codebase_learner
        |
        v
ecai_learning_store + ecai_learning_snapshot
        |
        v
ecai_content_evidence
        |
        v
ecai_content_generator --(Ollama, publishing role)--> content pack
        |
        v
ecai_content_validator
        |
        +--> article.md
        +--> docs.md
        +--> linkedin.txt
        +--> image-prompt.txt
        |
        v
ecai_image_renderer --> local PNG/JPEG
        |
        +--> ecai_blossom_client --> https://media.damagebdd.com
        |                              |
        |                              v
        |                         public media URL
        |                              |
        +--> ecai_nostr_content -------+--> NIP-23 kind 30023
        |
        +--> ecai_linkedin_client --> LinkedIn image + post
```

## Modules

- `ecai_content_sup` starts the publication store and manager.
- `ecai_content_store` persists jobs in `dets/content_pipeline.dets` and artifacts below `runtime/content/<job-id>/`.
- `ecai_content_evidence` constructs a publication evidence boundary from the current ECAI learned state.
- `ecai_content_generator` asks Ollama for one structured content pack using `role => publishing`, deterministic temperature 0, and explicit grounding rules.
- `ecai_content_validator` rejects incomplete packs, secret-like material and evidence references to unknown learned modules.
- `ecai_image_renderer` renders the generated image prompt against a local image API. `a1111` and an OpenAI-compatible image endpoint are included.
- `ecai_nostr_signer` sends signing requests through the existing `damage_nsecbunker` policy gate. It never loads vault material.
- `ecai_blossom_client` uploads the rendered image to `https://media.damagebdd.com` using a BUD-11 kind-24242 authorization event bound to the image SHA-256.
- `ecai_nostr_content` builds and publishes a kind-30023 long-form event using the Blossom media URL.
- `ecai_linkedin_client` initializes a LinkedIn image upload, uploads the local image, then creates a `/rest/posts` image post.
- `ecai_content_worker` is the persisted stage machine.
- `ecai_content_manager` deduplicates jobs by snapshot identity, resumes interrupted jobs, and optionally starts a new job when code learning completes with changes.
- `ecai_content` is the operator-facing API.

## Durable stages

Jobs progress through:

```text
evidence_ready -> generated -> validated -> rendered -> media_uploaded
               -> nostr_prepared -> nostr_published -> linkedin_published -> complete
```

A generated but not yet approved job uses `status => awaiting_publish` at the `rendered` stage. Failures use `status => retry` without rewinding the last completed stage, so a process/node restart resumes from persisted state instead of repeating completed network operations. The signed Nostr event is persisted at `nostr_prepared`; retries therefore republish the same event ID. If LinkedIn returns an ambiguous server/transport failure after post creation may have reached LinkedIn, the job moves to `manual_reconcile` instead of automatically creating a possible duplicate.

## Operator API

```erlang
%% Generate grounded text + local image but do not publish.
{ok, Job} = ecai_content:generate().

%% Scope generation to one learned module.
{ok, Job2} = ecai_content:generate(#{
    application => ecai,
    module => ecai_codebase_learner
}).

%% Execute the complete publish flow immediately.
{ok, Job3} = ecai_content:run().

%% Publish a previously generated/awaiting job.
ok = ecai_content:publish(maps:get(id, Job)).

%% Inspect and resume persisted state.
ecai_content:status().
ecai_content:jobs().
ecai_content:job(JobId).
ecai_content:artifact_dir(JobId).
ecai_content:resume().
ecai_content:retry(JobId).
```

`manual_reconcile` is intentionally excluded from automatic resume. After checking LinkedIn for an existing post, an operator may call `ecai_content:retry(JobId)` to explicitly retry the final publication stage.

`generate/0,1` creates a deterministic job for the current learning snapshot and stops at `awaiting_publish` after image rendering unless `content_auto_publish=true`. `run/0,1` sets `publish_requested=true` and continues through Nostr and LinkedIn.

## Configuration

Merge `sys.config.content.fragment` into the existing `ecai` configuration. Keep `content_auto_publish` false during rollout.

The existing Damage nsecbunker policy must authorize the pubkey configured as `content_nostr_requester_pubkey`, permit method `sign_event`, and permit kinds `24242` (Blossom authorization) and `30023` (long-form article). Do not call `damage_nsecbunker_secret_owner` from the publication subsystem.

LinkedIn OAuth credentials are read from the environment variable named by `content_linkedin_token_env`; do not store the token in source or `sys.config`. The shipped default API header is `Linkedin-Version: 202609` (September 2026) and remains configurable. The OAuth bearer token is sent both to the versioned REST endpoints and to the image upload URL returned by `initializeUpload`.

## Blossom

The default server is deliberately set in code to:

```text
https://media.damagebdd.com
```

Each upload computes SHA-256 from the exact rendered bytes. The BUD-11 authorization event contains:

```text
kind: 24242
tags:
  ["t", "upload"]
  ["x", <image sha256>]
  ["expiration", <unix timestamp>]
  ["server", "media.damagebdd.com"]
```

The signed event is encoded into the `Authorization: Nostr ...` header and the bytes are sent with `PUT /upload`. The returned descriptor SHA is checked against the local SHA before its URL can enter the Nostr article.

## Automatic generation hook

Apply `integration.patch`. After a learning cycle refreshes application/global knowledge and writes its snapshot, the learner notifies `ecai_content_manager` only when at least one application changed. Snapshot-derived job IDs make this notification idempotent.

With:

```erlang
{content_auto_generate, true},
{content_auto_publish, false}
```

a code change produces a new grounded job and render, but publication still requires `ecai_content:publish(JobId)`. Change the second setting to `true` only after the Nostr signer policy, Blossom server, image renderer and LinkedIn credentials have been exercised in your deployment.
