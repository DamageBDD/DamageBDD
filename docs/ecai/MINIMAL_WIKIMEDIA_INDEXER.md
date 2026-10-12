# Minimal ECAI Wikimedia Indexer

The `/indexer` page is intentionally small: sign in, choose a Wikimedia source,
queue it, and watch the durable job state.

The browser does **not** know source URLs, Cirrus releases, pageview files,
months, filesystem paths, selection tuning, chunk sizes, or artifact policy.
Those remain node-owned settings.

## API

```text
GET  /ecai/index-jobs/presets
POST /ecai/index-jobs/presets/:preset
GET  /ecai/index-jobs?kind=wikimedia_visibility&limit=50
GET  /ecai/index-jobs/status
POST /ecai/index-jobs/:id/pause
POST /ecai/index-jobs/:id/resume
POST /ecai/index-jobs/:id/cancel
POST /ecai/index-jobs/:id/retry
```

`POST /ecai/index-jobs/presets/:preset` accepts an empty JSON object only, expands
the preset on the node, and then uses the existing `ecai_index_jobs_srv` durable
queue. Browser-supplied preset overrides are rejected, so there is no second
indexing policy hidden in JavaScript.

## Built-in presets

- `enwiki` — English Wikipedia
- `simplewiki` — Simple English Wikipedia
- `dewiki` — German Wikipedia
- `frwiki` — French Wikipedia
- `eswiki` — Spanish Wikipedia

Every preset uses the node's rolling 12-month pageview window and `latest`
content release unless the node configuration overrides them.

## Node defaults

```erlang
{ecai, [
    {wikimedia_index_root, <<"/var/lib/damage/ecai/wikimedia">>},
    {wikimedia_preset_limit, 250000},
    {wikimedia_preset_publish_ipfs, false}
]}.
```

`wikimedia_preset_publish_ipfs` defaults to `false` so an otherwise valid
index build does not depend on IPFS publication. A deployment that wants
NFT-ready manifests can enable it at the node.

## Custom node-owned presets

A deployment may replace the built-ins without touching the browser:

```erlang
{wikimedia_index_presets, [
    #{
        id => <<"enwiki">>,
        label => <<"English Wikipedia">>,
        description => <<"Primary English knowledge corpus">>,
        project => <<"enwiki">>,
        pageview_project => <<"en.wikipedia">>,
        namespace => <<"org.damagebdd.wikimedia.en">>,
        limit => 500000,
        minimum_active_months => 6,
        publish_ipfs => false
    }
]}.
```

Only `id`, `label`, `description`, and `project` are returned to the browser.
Internal storage paths and indexing policy stay private to the node.
