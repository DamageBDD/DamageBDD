# ECAI Quick Index

Quick Index is the dashboard entry point for small, ad-hoc public/searchable sources. It accepts a browser file upload, a public HTTP(S) URL, or an IPFS CID, inspects the bytes deterministically, then submits the source to the existing durable `ipfs_cid` index-job path.

## Flow

The dashboard Overview highlights Quick Index as the recommended first action. Its CTA switches to the existing Index jobs panel and focuses the Quick Index card, so onboarding and indexing share one implementation rather than duplicating controls.

1. `POST /ecai/quick-index/inspect` acquires a bounded source and returns SHA-256 plus detected format/structure metadata.
2. The dashboard shows the detection result and only enables indexing for supported UTF-8 text/structured-text inputs.
3. `POST /ecai/quick-index` repeats acquisition, requires the SHA-256 returned by inspection, stages file/URL content in the configured local IPFS node, and enqueues the existing `ecai-index-job/v1` `ipfs_cid` job in `searchable_disk` mode.
4. Job persistence, restart recovery, progress events, retry controls and artifact finalisation remain owned by `ecai_index_jobs_srv` and its existing IPFS worker.

The inspection hash deliberately prevents a mutable URL from silently changing between preview and submission. IPFS CIDs are still re-read within the configured bound so the dashboard can report actual structure before queueing.

## Supported inputs

Quick Index currently recognises JSON, JSON Lines/NDJSON, CSV/TSV, Markdown, Org, HTML, XML, YAML, common source-code extensions and plain UTF-8 text. PDF, ZIP/Office containers and other binary data are rejected rather than being indexed as garbage bytes.

Detection is not the same as schema-aware ingestion. The current `ipfs_cid` searchable path indexes accepted source material with the existing deterministic UTF-8 window chunker. The dashboard therefore reports both the detected source structure and the actual indexing method.

## URL security boundary

URL ingestion only permits default-port HTTP/HTTPS destinations. It rejects userinfo, fragments, redirects, localhost names, `.local`/`.internal` names, and private/link-local/documentation/multicast address ranges. DNS is resolved before the request and the Gun connection is made to the validated resolved address so the fetch cannot be redirected by a second DNS lookup.

## Configuration

`quick_index_max_source_bytes` controls the Quick Index source bound and defaults to 16 MiB. The effective bound is also capped by `ingest_max_source_bytes` so this convenience endpoint cannot bypass the durable ingestion limit.

Quick Index uses the public/searchable indexing path. Confidential material belongs in the existing private-corpus workflow rather than this endpoint.
