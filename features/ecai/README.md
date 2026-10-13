# ECAI Wikimedia / durable index-job BDD suite

The operational indexing lifecycle is `/ecai/index-jobs`. Wikimedia exposes
source discovery, planning, search, and doctor endpoints only. The economic
chunk marketplace remains a separate `/ecai/market/jobs` API.

## Profiles

- `jobs-contract`: `index_jobs_max_concurrency = 0`.
- `fixture` / `ipfs`: `index_jobs_max_concurrency = 1`; the Wikimedia fixture
  server is an OTP-managed ECAI worker.
- `network`: live Wikimedia discovery; keep out of deterministic per-commit CI.
- `pending`: explicit hardening contracts only.

## Runner

Use the single runner:

```sh
bash scripts/ecai-bdd/run_wikimedia_features.sh list
bash scripts/ecai-bdd/run_wikimedia_features.sh jobs-contract
bash scripts/ecai-bdd/run_wikimedia_features.sh fixture
bash scripts/ecai-bdd/run_wikimedia_features.sh ipfs
```

The runner does not start or kill a Python/sidecar fixture server. For fixture
profiles it waits for the supervised listener and reads the generated pinned
catalog from `/_ecai/fixture/status`.

API features use portable placeholders:

```text
{{ECAI_BASE_URL}}
{{ECAI_ACCESS_TOKEN}}
```

DamageBDD scenario variables such as `{{RunId}}` and `{{IndexJobId}}` remain
unmodified by the runner.

## API surface

```text
GET  /ecai/wikimedia/sources
GET  /ecai/wikimedia/plan
GET  /ecai/wikimedia/search
GET  /ecai/wikimedia/doctor

GET  /ecai/index-jobs
POST /ecai/index-jobs
GET  /ecai/index-jobs/status
GET  /ecai/index-jobs/:id
POST /ecai/index-jobs/:id/pause
POST /ecai/index-jobs/:id/resume
POST /ecai/index-jobs/:id/cancel
POST /ecai/index-jobs/:id/retry
GET  /ecai/index-jobs/:id/artifact
GET  /ecai/index-jobs/:id/events
```

Wikimedia artifacts use `ecai-index-manifest/v2`, `ecai-index-nft/v2`, and
`ecai-posting-proof/v2`. The pre-existing v1 search/proof APIs remain available
for compatibility.
