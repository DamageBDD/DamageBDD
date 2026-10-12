# DamageBDD NIP-96 over IPFS

This implementation adds a NIP-96 HTTP surface backed by the existing DamageBDD IPFS/Kubo subsystem.

## Modules

- `damage_nip98.erl` — strict NIP-98 HTTP auth validation (kind, freshness, exact URL, method, signature) plus NIP-96 file-payload binding.
- `damage_nip96_store.erl` — durable DETS mapping from original SHA-256 to IPFS CID and per-Nostr-pubkey ownership metadata.
- `damage_nip96_http.erl` — `/.well-known/nostr/nip96.json`, upload/list/download/delete endpoints.
- `damage_ipfs_sup.erl` — patched to supervise the NIP-96 metadata store.
- `damage_app_nip96.patch` — adds `damage_nip96_http` to the Trails handler list.

## Routes

- `GET /.well-known/nostr/nip96.json`
- `POST /api/nip96` (NIP-98 required, multipart `file` field)
- `GET /api/nip96?page=0&count=20` (NIP-98 required)
- `GET /api/nip96/<sha256>[.ext]`
- `DELETE /api/nip96/<sha256>[.ext]` (NIP-98 required)

Uploads are streamed to a private temporary file under the configured IPFS data directory while SHA-256 is calculated. The client-provided multipart filename is never used as a filesystem path. The completed file is added to IPFS, registered for durable pinning, and the temporary file is deleted.

Downloads are served through the DamageBDD endpoint rather than redirecting to a public gateway. The fetched IPFS bytes are re-hashed and must match the NIP-96 `ox` hash before they are returned.

## Optional configuration

All settings have defaults. For a reverse-proxied deployment, set the public origin explicitly so NIP-98 exact-URL validation uses the externally visible HTTPS URL:

```erlang
{nip96_public_base_url, "https://run.damagebdd.com"},
{nip96_max_bytes, 67108864},
{nip96_upload_timeout_ms, 120000},
{nip98_skew_seconds, 60},
{nip96_pin_uploads, true},
{nip96_unpin_on_delete, false}
```

`nip96_unpin_on_delete` defaults to `false` because DamageBDD shares the IPFS pin namespace with other subsystems. Deleting the final NIP-96 owner always removes the HTTP-visible NIP-96 object mapping; set this option to `true` only when NIP-96 is authoritative for those pins.

## Integration

Copy the three new modules into `apps/damage/src/`, use the patched `damage_ipfs_sup.erl`, and add `damage_nip96_http` to `damage_app:get_trails/0` (see `damage_app_nip96.patch`).

Then compile in the DamageBDD checkout:

```sh
rebar3 compile
```
