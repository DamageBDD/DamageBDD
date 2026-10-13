# DamageBDD scoped context

This implementation replaces contract-backed context values with a fast,
encrypted, versioned off-chain store. A single standard Aeternity contract is
used only for fixed-size context commitments.

## Ownership model

| Scope | Storage owner | Anchor caller | Intended use |
|---|---|---|---|
| `node` | Node wallet | Node wallet | Inheritable node defaults and private node configuration |
| `{account, Account}` | Authenticated account | Account wallet | User-specific context |
| `{wallet, Account, WalletId}` | Account | Account wallet | Future isolated custodial wallet configuration |
| `{agent, Account, AgentId}` | Account | Account wallet | Future account-owned agent configuration |

The HTTP API never accepts an owner address. Account ownership comes from the
authenticated Cowboy state. Node routes require the authenticated account to be
listed in `damage.node_admins`; the node wallet is not implicitly privileged and
must be listed when it should administer node context. On-chain node anchors are
still signed by the node wallet.
listed in the fail-closed `damage.node_admins` application environment setting.
The node wallet has no implicit exception and must be listed when it should have
HTTP administrator access.

## Programmatic API

```erlang
%% Node default inherited by accounts.
{ok, _} = damage_context:put(
    node,
    <<"default_server">>,
    <<"https://api.example.com">>,
    #{inheritance => default, exposure => template}
).

%% Node value that accounts cannot override.
{ok, _} = damage_context:put(
    node,
    <<"required_region">>,
    <<"au-syd">>,
    #{inheritance => locked, exposure => template}
).

%% Isolated account secret. It may be rendered for that account's BDD run,
%% but is redacted from API responses and formatter output.
{ok, _} = damage_context:put(
    {account, UserAccount},
    <<"api_token">>,
    Token,
    #{sensitive => true}
).

%% Future account-owned wallet scope.
{ok, _} = damage_context:put(
    {wallet, UserAccount, WalletId},
    <<"daily_limit_msat">>,
    100000000,
    #{}
).

Effective = damage_context:effective_context(
    UserAccount,
    RunContext,
    [{wallet, UserAccount, WalletId}]
).
```

The merge order is:

```text
system defaults
< node defaults
< account values
< wallet/agent values
< per-run values
< locked node values
< protected runtime identity
```

Protected runtime keys such as `public_key`, `private_key`, `access_token`,
`node_public_key`, `token_contract`, `run_id`, and `report_hash` cannot be stored
as context keys.

## Node-secret boundary

A sensitive node value is always normalized to:

```erlang
#{
    sensitive => true,
    exposure => step_only,
    inheritance => none,
    locked => true
}
```

It is never added to user-authored Gherkin template context. Trusted Erlang
steps can read it explicitly with `damage_context:get(node, Key)` after applying
their own authorization policy.

## Storage

`damage_context_store` owns one shared ETS cache and one DETS file. Snapshots are
AES-256-GCM encrypted. The encryption key is derived per scope from a random
master key stored through the existing `secrets` vault, and the authenticated
additional data binds the ciphertext to its exact scope and version.

Default data file:

```text
data/damage_context_v2.dets
```

The store keeps a current snapshot row for fast reads and a versioned encrypted
witness row for every committed local version. A report can therefore retain the
exact AES-GCM envelope used to calculate its context root even after the live
scope advances to a newer version. Witness rows contain ciphertext, IV, tag, and
AAD only; plaintext context values are never copied into the report.

At run preparation, sensitive values are frozen behind an opaque reference in a
separate protected ETS table. Formatters resolve that reference instead of
re-reading mutable scope state, so a secret remains redacted even when its live
context entry changes during execution. The reference expires according to
`context_redaction_ttl_seconds` and is never written into report artifacts.

Configuration overrides:

```erlang
{context_data_dir, "/var/lib/damage"},
{context_store_file, "/var/lib/damage/context.dets"},
{context_max_bytes, 1048576},
{context_max_request_bytes, 1048576},
{context_sync_writes, true}
```

For normal reads and writes there are no blockchain or IPFS calls.

When `damage_access_token:maybe_refresh/2` materializes a new account credential,
the refreshed value is written as a versioned account-context update before the
run snapshot is finalized. The proof and encrypted witness therefore commit to
the credential value actually used by execution, not the stale pre-refresh row.


## Standard anchor contract

The shared `Context` contract stores only:

```text
Call.caller -> namespace -> {version, sha256_root, updated_at}
```

It has no admin write entrypoint and no `commit_for` function. A caller can only
advance its own namespace.

- Node context is signed by the node wallet.
- Custodial account context is signed by the user's inner key while the node may
  pay the outer `PayingFor` transaction.
- When no custodial key is available, `damage_context:anchor/1` returns an
  unsigned transaction intent for the wallet to sign and broadcast.

The public API deliberately does **not** accept a generic signed transaction for
node-paid forwarding. Sponsoring a non-custodial anchor requires a validator
that decodes the signed inner transaction and proves that its contract,
entrypoint, owner, namespace, version and root match a live server-issued
intent. Until that validator exists, `submit_signed_anchor/1` fails closed.

## Bootstrap

Deploy or recover the shared contract during node-admin bootstrap:

```erlang
{ok, Contracts} =
    damage_contract_bootstrap:bootstrap_node_admin(NodeAdminAccount),
ContextCt = maps:get(context, Contracts).
```

Targeted bootstrap is also available:

```erlang
{ok, ContextCt} =
    damage_contract_bootstrap:ensure_context_contract(NodeAdminAccount).
```

User bootstrap creates the isolated account scope and records the shared
contract pointer in the user's AccountRegistry when a custodial key is present:

```erlang
{ok, UserContracts} =
    damage_contract_bootstrap:bootstrap_user_account(UserAccount).
```

The bootstrap validates candidate context contracts with `get_anchor`. The old
full-value context contract does not implement that interface, so it is rejected
and replaced instead of being silently reused.

## HTTP API

Authenticated account:

```text
GET    /context
POST   /context
PATCH  /context
DELETE /context?key=KEY
GET    /context/effective
GET    /context/anchor
POST   /context/anchor
```

Configured node administrators only:

```text
GET    /node/context
POST   /node/context
PATCH  /node/context
DELETE /node/context?key=KEY
GET    /node/context/anchor
POST   /node/context/anchor
```

Configure the accounts allowed to use these routes:

```erlang
{node_admins, [
    <<"ak_first_admin">>,
    <<"ak_second_admin">>
]}
```

The setting fails closed: a missing, empty, or malformed `node_admins` value
grants no node-context HTTP access. The node wallet must be included explicitly
when it should have administrator access.


Single-value write:

```json
{
  "key": "api_token",
  "value": "secret",
  "sensitive": true
}
```

Atomic versioned change set:

```json
{
  "expected_version": 7,
  "set": {
    "server": {
      "value": "https://example.com",
      "sensitive": false
    }
  },
  "delete": ["old_server"]
}
```

A stale `expected_version` returns `409 VERSION_CONFLICT`. Sensitive values are
returned as `XX-REDACTED-XX`, and responses use `Cache-Control: private, no-store`.

## Run proof

`damage.erl` freezes each required scope once at run start and derives both the
execution values and proof from that same snapshot. It writes schema-v2
`context_proof.json` before the run directory is added to IPFS.

Each non-empty proof includes the base64-encoded AES-GCM IV, authentication tag,
ciphertext, and AAD for the exact scope version. A verifier can recompute:

```text
sha256(IV || TAG || CIPHERTEXT) == context root
```

The report hash therefore commits to a durable encrypted witness for the node and
account contexts, plus any selected wallet/agent scopes, with no extra
transaction per run. Empty version-zero scopes include their deterministic root
preimage instead of an encrypted envelope.

## Migration

The previous context contract stored encrypted values on-chain with an
incompatible interface and, in the uploaded version, could not bootstrap the
first account. This patch intentionally does not read it on the hot path.

If a deployment has valuable data in another working legacy context contract,
export and decrypt it before replacing the module, then import it with
`damage_context:apply_changes/2`. The new default DETS filename is versioned to
avoid interpreting an experimental earlier local-store format as this schema.

## Supervision

`damage_context:ensure_started/0` lazily starts the shared store, so existing
callers continue to work. For normal production supervision, add one permanent
worker using either `damage_context:start_link/0` or
`damage_context_store:start_link/0`; do not create one worker per account.
