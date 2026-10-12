# DamageBDD Blossom over IPFS

This adds a Blossom HTTP facade over the same SHA-256 -> IPFS CID object store used by the DamageBDD NIP-96 implementation.

## Implemented BUD surface

- BUD-01: `GET /<sha256>[.ext]`, `HEAD /<sha256>[.ext]`, CORS, ETag and single byte-range responses.
- BUD-02: `PUT /upload` with an unmodified binary request body and Blossom Blob Descriptor response.
- BUD-06: `HEAD /upload` preflight using `X-SHA-256`, `X-Content-Type`, and `X-Content-Length`.
- BUD-11: Nostr kind `24242` authorization with `t`, `expiration`, optional `server`, and required matching `x` hash scope for upload/delete.
- BUD-12: `DELETE /<sha256>` and optional cursor-paginated `GET /list/<pubkey>`.

The implementation intentionally does not add BUD-04 mirror, BUD-05 media transformation, BUD-07 payments, or BUD-09 reporting in this patch. These can be layered on the same content store later.

## Routes

Blossom requires its endpoints at the server root:

```text
PUT     /upload
HEAD    /upload
GET     /<sha256>[.ext]
HEAD    /<sha256>[.ext]
DELETE  /<sha256>
GET     /list/<pubkey>?cursor=<sha256>&limit=20
OPTIONS /*
```

`damage_blossom_http` must remain the last Trails handler because `/:blob` is a root catch-all. Existing DamageBDD routes are therefore matched first.

## Authentication

Uploads and deletes require BUD-11 authorization:

```text
Authorization: Nostr <base64url-no-padding JSON event>
```

The signed event must be kind `24242` and contain:

```json
{
  "kind": 24242,
  "content": "Upload Blob",
  "tags": [
    ["t", "upload"],
    ["expiration", "<future unix timestamp>"],
    ["x", "<lowercase sha256>"],
    ["server", "cdn.example.com"]
  ]
}
```

The `server` tag is optional. If present, it is checked against the hostname derived from `blossom_public_base_url` (falling back to the NIP-96/public API origin).

`GET /list/<pubkey>` is disabled by default because BUD-12 marks listing as optional and unrecommended. When enabled, it can remain public or require BUD-11 `t=list` authorization.

## Upload example shape

Clients compute the SHA-256 before uploading because authenticated Blossom upload tokens must scope the operation to that hash.

```sh
HASH=$(sha256sum picture.png | awk '{print $1}')
SIZE=$(wc -c < picture.png | tr -d ' ')

curl -X PUT https://cdn.example.com/upload \
  -H "Authorization: Nostr $BUD11_TOKEN" \
  -H "X-SHA-256: $HASH" \
  -H "Content-Type: image/png" \
  -H "Content-Length: $SIZE" \
  --data-binary @picture.png
```

A new object returns `201`; an already-present object returns `200`. The response is a Blossom Blob Descriptor and includes an additional `ipfs` field:

```json
{
  "url": "https://cdn.example.com/<sha256>.png",
  "sha256": "<sha256>",
  "size": 12345,
  "type": "image/png",
  "uploaded": 1780000000,
  "ipfs": "ipfs://bafy..."
}
```

## Suggested config

```erlang
{blossom_public_base_url, "https://cdn.example.com"},
{blossom_max_bytes, 67108864},
{blossom_upload_timeout_ms, 120000},
{blossom_pin_uploads, true},
{blossom_unpin_on_delete, false},

%% BUD-12 listing is optional/unrecommended.
{blossom_list_enabled, false},
{blossom_list_require_auth, false},
{blossom_list_allow_others, true}
```

`blossom_unpin_on_delete` defaults to `false` because DamageBDD's Kubo pin set may contain references owned by subsystems outside this HTTP metadata store.

## Storage compatibility

Object records remain shared:

```text
{object, SHA256} -> #{cid, size, content_type, extension, created_at, ...}
```

Existing NIP-96 owner keys remain unchanged:

```text
{owner, SHA256, Pubkey} -> OwnerMeta
```

Blossom ownership uses a separate source-scoped key:

```text
{owner, blossom, SHA256, Pubkey} -> OwnerMeta
```

This preserves existing DETS data and prevents cross-protocol deletes while allowing both surfaces to reference the same IPFS object.

## Validation

The included incremental patch was checked with `git apply --check` against the previously generated NIP-96 implementation. The cumulative patch was also checked against the pre-NIP-96 baseline.

This environment does not include Erlang/rebar3, so run the normal project compiler/test suite after applying:

```sh
git apply --check blossom_ipfs.patch
git apply blossom_ipfs.patch
rebar3 compile
rebar3 eunit
```
