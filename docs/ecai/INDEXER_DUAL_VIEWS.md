# ECAI indexer dual views

The indexer exposes two authenticated views over the same durable job API.

- `/indexer` is the default preset-first Wikimedia indexer. The browser submits only a server-owned preset id.
- `/indexer/advanced` preserves the full operator console for raw normalized job specs, source discovery, planning, search, SSE progress, artifact inspection and lifecycle controls.

Both views authenticate existing DamageBDD users with `/accounts/auth/`, use the same session/bearer token, and operate on `/ecai/index-jobs`. The advanced view does not restore deprecated `/ecai/wikimedia/index`, `/ecai/jobs`, or static indexer entrypoints.

Static assets are intentionally separate:

- `/static/js/ecai-indexer.js` and `/static/css/ecai-indexer.css` — simple default view
- `/static/js/ecai-indexer-advanced.js` and `/static/css/ecai-indexer-advanced.css` — full operator view

Keeping separate asset names prevents the minimal UI from accumulating the advanced console's DOM assumptions.
