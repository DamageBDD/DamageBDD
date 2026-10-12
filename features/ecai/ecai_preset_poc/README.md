# ECAI Wikimedia preset POC

This proof-of-concept exercises the real server-owned preset path without
waiting for a complete public Wikimedia corpus build.

## What it proves

The feature checks:

1. the durable queue is running with the integration profile (`max_concurrency = 1`);
2. the `simplewiki` server-owned preset is exposed;
3. the preset can be enqueued with an explicit idempotency key;
4. a durable job id is returned;
5. the worker reaches `running` and exposes progress;
6. the job control plane can cancel the live job.

This covers the useful smoke-test path:

DamageBDD auth -> ECAI preset API -> preset expansion -> durable queue ->
Wikimedia worker -> progress persistence -> cancellation.

It intentionally does not wait for final artifact generation.

## Run

```bash
export DAMAGEBDD_BASE_URL='http://127.0.0.1:4888'
export DAMAGEBDD_TOKEN='...'

./run_ecai_wikimedia_preset_poc.sh
```

If the ECAI API is served at a different origin:

```bash
export ECAI_BASE_URL='https://ecai.damagebdd.com'
export ECAI_ACCESS_TOKEN="$DAMAGEBDD_TOKEN"
./run_ecai_wikimedia_preset_poc.sh
```

## Expected profile

Run the node with the normal Wikimedia integration profile:

```erlang
{index_jobs_max_concurrency, 1}
```

The feature deliberately asserts this value so it fails immediately if it is
accidentally run against the contract profile (`max_concurrency = 0`).

## Expected successful path

You should see:

- `GET /ecai/index-jobs/status` -> 200
- `GET /ecai/index-jobs/presets` -> 200 and `simplewiki`
- `POST /ecai/index-jobs/presets/simplewiki` -> 202
- a stored `IndexJobId`
- after the worker starts, `GET /ecai/index-jobs/:id` -> state `running`
- `POST /ecai/index-jobs/:id/cancel` -> 202
- final inspection containing `cancel_requested` or `canceled`

If the worker fails before reaching `running`, the POC fails on purpose: that
means source discovery/network/configuration or the indexing pipeline needs
inspection.
