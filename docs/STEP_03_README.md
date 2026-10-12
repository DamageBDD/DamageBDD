# ECAI Step 03 — durable committed-batch WAL

This cumulative DamageBDD patch adds the first durable ingest boundary for the
ECAI IPFS index.

Core result:

```text
validated deterministic records
→ batch_begin + events + batch_commit
→ file:sync
→ durable acknowledgment
→ restart replay and event_id deduplication
```

A successful Step 3 acknowledgment is durable in the local WAL but deliberately
reports `index_searchable => false`. Immutable index publication is Step 4.

Start with:

```text
docs/STEP_03_DURABLE_WAL.md
```

Verify package contents with:

```sh
sha256sum -c SHA256SUMS
```
