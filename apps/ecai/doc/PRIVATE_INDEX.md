# Private ECAI indexing and permissioned LLM retrieval

## What this patch implements

An explicit, append-only private indexing path alongside the existing public
indexer. It reuses `ecai_terms`, `secrets_pqc`, the scoped `secrets` vault, the
existing authentication helper and `ecai_ollama_client`. It does not introduce a
second KEM, wallet, password derivation scheme, embedding client or LLM pool.

Each submitted batch is one immutable encrypted segment. **The whole term
index, posting lists and all source records are encrypted together**, before any
bytes reach disk. Private segments do not enter the public DETS docstore, ingest
WAL, manifest, snapshots, job artifacts, on-chain headers or shared hot cache.

Searching is a trusted-worker operation, not computation on ciphertext. It
reads/decrypts each segment in turn, matches the existing canonical term keys,
keeps the best results, and returns authorised plaintext. **All records in the
currently scanned segment are decrypted**, not just the eventual matches. Only
the selected, bounded excerpts are sent to an approved LLM destination. No
embedding reranking or automatic provider fallback is used.

This is a correctness/confidentiality-first v1, not a billion-document private
search engine. Public indexes and their formats remain unchanged.

## Files and entry points

- `ecai_disk_indexer:index_private/4` delegates to `ecai_private_index:index/4`.
- `ecai_private_index:search/4` returns ranked, decrypted source maps.
- `ecai_private_index:fetch/3` decrypts a source by its opaque result reference.
- `ecai_ollama_rag:ask_private/4` and `ecai_llm_bridge:ask/4` provide private RAG.
- `ecai_private_keys:provision/2` creates a new randomly named scoped vault entry.
- `ecai_private_http` adds authenticated `index`, `search`, `fetch`, and `ask` POST
  endpoints, registered through `ecai_app`.

Low-level helpers are trusted BEAM APIs, not security boundaries against other
code running in the same VM. The HTTP handler obtains the principal only from
`damage_auth:authenticated_account/1`; it does not trust a body-supplied owner.
There is no anonymous/operator-mode fallback on these private routes.

## Configure the existing PQC backend and provision a corpus key

Build/install your supplied `secrets_pqc`, `secrets_pqc_oqs` and liboqs NIF in the
normal DamageBDD build. The existing secrets service must be running and
unlocked. The private modules never generate a replacement signing identity or
change the node wallet password themselves.

Run this in a trusted local Erlang shell:

```erlang
application:set_env(damage, pqc_backend_module, secrets_pqc_oqs).
Owner = <<"ak_REPLACE_WITH_AUTHENTICATED_ACCOUNT">>.
Corpus = <<"engineering-private">>.
{ok, KeyRef} = ecai_private_keys:provision(Owner, Corpus).
```

`KeyRef` contains `key_name`, `key_id`, and `public_key_sha256`, **not the private
key**. Provisioning is an explicit operator action; it does not rewrite an
existing corpus configuration. Preserve the returned references and back up
the existing scoped secrets vault and its unlocking material. Do not repeatedly
provision keys as a substitute for unlocking an existing corpus.

Configure the corpus without putting private keys in `sys.config`:

```erlang
Config = #{
    owner => Owner,
    base_dir => "/var/lib/damage/ecai/private/engineering-private",
    key_name => maps:get(key_name, KeyRef),
    key_id => maps:get(key_id, KeyRef),
    readers => [],
    writers => [],
    llm_destinations => [<<"local-ollama">>],
    allow_remote_llm => false
}.
Existing = application:get_env(ecai, private_corpora, #{}).
application:set_env(ecai, private_corpora, Existing#{Corpus => Config}).
```

The owner can read and write. `readers` can retrieve, and `writers` can append;
a writer is not automatically a reader. These are corpus-wide ACLs. Separate
corpora are required for different record-level access boundaries in this v1.
Use the exact authenticated account bytes, not a display name.

The base directory must be dedicated and empty initially. The implementation
creates it with mode `0700` and files with `0600`. An existing directory must
already have mode `0700`. Its parent and ancestor directories must be controlled
by the operator. Public data is never silently converted in place. Deploy one
writer node per local filesystem; this implementation is not a shared-volume
multi-node lease protocol.

Persist the settings in your real configuration; runtime `application:set_env`
changes do not survive restart. A mergeable example is at
`apps/ecai/priv/config/private_index.example.config`.

## Index and retrieve

```erlang
BatchId = ecai_index_job_codec:id_hex(crypto:strong_rand_bytes(16)).
{ok, Ack} = ecai_disk_indexer:index_private(Corpus, Owner, BatchId, [
    #{title => <<"Release procedure">>,
      heading => <<"Verification">>,
      text => <<"Private releases require passing DamageBDD acceptance tests.">>,
      tags => [<<"release">>],
      type => <<"internal">>}
]).

{ok, Search} = ecai_private_index:search(Corpus, Owner, <<"acceptance tests">>, 8).
[First | _] = maps:get(sources, Search).
{ok, Decrypted} = ecai_private_index:fetch(Corpus, Owner, maps:get(id, First)).
```

Retain the random 32-character lowercase hexadecimal batch ID across retries.
An existing batch returns `{error, batch_already_exists}`; it is never replaced.
This is collision/refusal semantics, not an acknowledgement that a retried
payload equals the original. Following a timeout, the batch may already have
committed; do not blindly submit it again with a new ID.

A result reference is `batch_id:ordinal`, not a hash of plaintext. Sorting is
by descending number of matched term keys, then the opaque reference for
stable ties. A score is a lexical match count, not confidence or a truth score.
A binary question searches `text`; a structured map uses the existing fielded
query pipeline, for example `#{title => <<"release">>, prefix => true}`.

Supply already chunked records. The private path preserves `ecai_terms/v1`
semantics, including its existing text-token cap; it does not invent a new
semantic/geometric retrieval model or automatically ingest arbitrary URLs.
The closed record schema accepts the existing chunk/event metadata fields,
normal text fields and selected directory fields. Unknown fields and ambiguous
atom/binary duplicate keys are rejected rather than silently discarded.

## Bridge to a local LLM

Configure a specific installed model, not a pool:

```erlang
Destination = #{trust => local, options => #{
    provider => ollama,
    host => "127.0.0.1",
    port => 11434,
    model => <<"REPLACE_WITH_INSTALLED_LOCAL_MODEL">>
}}.
Destinations = application:get_env(ecai, private_llm_destinations, #{}).
application:set_env(ecai, private_llm_destinations,
                    Destinations#{<<"local-ollama">> => Destination}).

{ok, Answer} = ecai_ollama_rag:ask_private(
    Corpus, Owner, <<"Which acceptance tests are required for releases?">>,
    <<"local-ollama">>).
```

Only literal `127.0.0.1` and `::1` with the Ollama provider are accepted for
`trust => local`. This checks the immediate network hop; it cannot verify that
the local service itself does not forward to a cloud service. Disable cloud
routing and audit the local model service separately.

The bridge validates destination permission before key access, then rechecks
permission and destination immediately before generation. It uses the existing
client directly, never `ecai_ollama_pool`. It sends no private key, corpus
configuration, arbitrary source metadata, tool definitions or filesystem paths.
Selected title, heading and text fields are treated as untrusted evidence, with
short source labels for citation. The existing client now maps its `system`
option to Ollama's `system` field or the OpenAI Responses `instructions` field.
No matching evidence means no model request.

There is no request-selected host, provider, model, TLS configuration, proxy,
callback module or tool. The two adapter module settings are **operator-only**:
`private_key_provider_module` defaults to `ecai_private_keys`, and
`private_llm_client_module` defaults to `ecai_ollama_client`. Do not expose
application environment mutation to untrusted callers.

For a remote model, define an operator destination with `trust => remote`,
include its ID in this corpus's `llm_destinations`, and explicitly set
`allow_remote_llm => true`. The bridge forces TLS with the existing client's
normal certificate-verification defaults, direct networking, and `store =>
false`; caller-supplied TLS overrides are not forwarded. **A remote service
still receives the selected plaintext.** `store => false` is not a claim about
all provider logging, retention or training policies.

## HTTP interface

Routes are registered at boot. For a running development node after loading
the changed modules, use your normal router reload/restart procedure.
Terminate HTTPS before the existing clear-text Cowboy listener; do not expose
private requests over an unprotected network.

| POST route | Required JSON fields |
| --- | --- |
| `/ecai/private/:corpus/index` | `batch_id`, `records` |
| `/ecai/private/:corpus/search` | `query`; optional `limit` |
| `/ecai/private/:corpus/fetch` | `id` |
| `/ecai/private/:corpus/ask` | `question`, `destination` |

Use the existing DamageBDD authentication mechanism. Owner/keys/path/model
options supplied in these request bodies are rejected. Successful responses
contain `ok` and `result`, and all private responses set `Cache-Control:
no-store, private`. Binary commitment fields are hex-encoded at this JSON
boundary. Private questions are POST bodies, not URL query strings.

The public durable job queue intentionally does **not** accept private jobs.
It persists source/job metadata and can publish public artifacts. Privacy flags
are now rejected before public normalization, and configured private target
paths are rejected. The private routes are synchronous bounded submissions;
there is no private queue UI, private IPFS source fetcher, automatic background
reindexing, or encrypted job-resume journal in this patch.

## Limits and failure behaviour

The implementation has fixed conservative limits: 256 records and 8 MiB of
serialized record input per batch, 1 MiB per record, approximately 32 MiB per encrypted
segment, 1,024 segments per corpus, and a 256 MiB ciphertext scan budget per
query. Private HTTP bodies are capped at 1 MiB, private query input at 16 KiB,
and results at 50. The LLM path selects at most eight results, clips each text
to 6,144 bytes without splitting UTF-8, and caps the encoded prompt at 96 KiB.
It rejects oversized encoded evidence rather than silently sending more.

Operations run in short-lived sensitive workers with bounded heap, redacted
exception boundaries and a 120-second ceiling. The LLM client timeout is
60 seconds. Workers are killed when their caller dies. These are operational
bounds, not a guaranteed memory-zeroization mechanism. A request already sent
to a model service cannot be recalled by killing the worker.

Corrupt ciphertext, wrong keys, wrong recipient/scope, renamed segments,
unknown segment versions and malformed encodings fail closed. There is no
plaintext fallback. Compressed external terms are refused before safe decoding;
trailing bytes are refused as well. Private files are published atomically
without replacement after syncing the ciphertext file. **Directory-entry fsync
and guaranteed power-loss durability are not implemented**; this is not a
replacement for a transactional storage engine or backups.

## Security boundaries and omissions

- This protects stored corpus contents and term/posting data from plaintext
  exposure in the new on-disk format. File count, ciphertext length, modification
  time and I/O behaviour remain visible. Searches decrypt segments in the trusted
  process; this is not FHE, PIR or oblivious search.
- It does not defend against a compromised host, privileged BEAM code, hostile
  NIFs, memory inspection, swap, or core/crash dumps. Audit those separately.
- AES-GCM/context binding rejects modified existing envelopes. Public-key
  encryption is **not writer authentication**: an attacker with the public key
  and storage write access can construct a new valid envelope. Signed manifests,
  provenance authentication and rollback/deletion detection are not provided.
- The vault adapter uses the supplied node-scoped secrets protection; this is
  not non-exportable HSM custody, a complete X.509 PKI/certificate lifecycle, or
  a blanket post-quantum claim for every part of the system.
- Revocation applies to future authorization/key use, with checks at release/
  dispatch boundaries. It cannot claw back plaintext, cached external responses,
  old keys or an already-dispatched model request. Key rotation, record updates,
  deletion and compaction require a new corpus/rebuild in this v1.
- No private content is intentionally logged by the new code. `damage_gun`,
  authentication middleware, telemetry, reverse-proxy logs, model-service logs
  and OS crash/swap behaviour still require a deployment audit; their complete
  implementations were not supplied for this change.
- Source instructions cannot grant application permissions or invoke tools
  through this bridge. They can still influence a language model's answer.
  A generated citation is not a cryptographic proof that the claim is supported.

## Validation and tests

This patch was constructed against the supplied `latest-ecai.tar.gz` and the
provided secrets APIs. The editing environment has no Erlang/OTP or Rebar3, and
package installation could not reach its repository. **No Erlang compilation,
EUnit execution, real liboqs operation or live LLM/HTTP integration was performed
there.** Do not describe the included tests as passing until run in your build.

There are 26 EUnit cases in `ecai_private_index_tests`, plus an explicitly opt-in
real liboqs smoke test. Fixtures reuse the supplied
`secrets_pqc_api_tests` fake backend, not a duplicated crypto implementation.
Ensure that existing fixture is on the umbrella test code path. Tests use
random temporary directories and injected test adapters; they do not start a
funded wallet, production vault, ECAI application or network model service.

From the DamageBDD repository root:

```sh
rebar3 compile
rebar3 eunit --module=ecai_private_index_tests

# Requires the real secrets_pqc_oqs NIF and liboqs to be built/loadable:
ECAI_PRIVATE_REAL_PQC_TEST=1 rebar3 eunit --module=ecai_private_index_tests
```

Also run the existing public-index, job-codec, ingest and Ollama-client test
suites to catch compatibility regressions. Live authentication, TLS behaviour
and the actual local/remote model destination still need deployment integration
tests. Static checks and a patch-application check are recorded separately in
the accompanying validation report.
