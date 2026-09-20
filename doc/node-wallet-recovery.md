# Node wallet recovery and verification

## Compatibility and scope

New node wallets use a 12-word English BIP-39 phrase, generated from 128 bits of
`crypto:strong_rand_bytes/1` entropy. The production derivation has an empty
BIP-39 passphrase and the all-hardened AEX-10 path `m/44'/457'/0'/0'/0'`.

The implementation validates the word count, wordlist membership and checksum
before deriving a key. It does not autocomplete, autocorrect, or invent a phrase
from an existing signing key. Imports accept valid English phrases with 12,
15, 18, 21 or 24 words, but always derive this same account-zero/address-zero
path. Unsupported derivation metadata is rejected, not ignored.

Existing random-key keystores are neither regenerated nor rewritten. Do not
delete an existing funded/registered node's `damage.key` to enable this feature.
That changes its identity and can also make application secrets encrypted with
the old signing key inaccessible. Deliberate identity migration is outside this
patch; retain the original encrypted keystore and its password.

The code is aligned with the specifications listed below. A restoration in the
installed Superhero Wallet UI has not been executed as part of this patch.
Before production use, restore a disposable generated phrase in Superhero and
compare the complete `ak_...` address against the node's account-zero address.
Never use the public test fixtures for funds or a production node.

## APIs

`secrets:make_keypair/0` returns a newly generated wallet map, or a controlled
`{error, Reason}`. `secrets:keypair_from_mnemonic/1` reconstructs a wallet map
without changing any keystore or running identity. These two pure construction
APIs intentionally return private material and must be handled accordingly.

The persisted wallet map includes `public_key`, `private_key`, `mnemonic`,
`wallet_scheme = aex10_bip39`, `derivation_path`, `account_index = 0`, and
`address_index = 0`. The complete map is encrypted by the existing node-password
envelope before being stored on disk.

Routine `secrets:node_keypair/0` replies still contain only `public_key` and
`private_key`. The long-lived signing cache contains no mnemonic. Root recovery
material is retrieved separately:

```erlang
%% Trusted operator session only: the success result contains the recovery phrase.
damage_ae:export_node_wallet_seedphrase().
```

The dedicated export reads the existing encrypted keystore and validates the
wordlist/checksum, wallet metadata, freshly regenerated Ed25519 public key,
full 64-byte NaCl signing key, and derived address. It also checks against the
active signing identity if one is cached. It returns `{ok, ExportMap}` only
when the phrase restores that exact keypair. A different valid phrase returns
`{error, {invalid_wallet_backup, mnemonic_keypair_mismatch}}` when encountered
while loading the keystore, or `{error, mnemonic_keypair_mismatch}` from the
pure `damage_ae_wallet:export_seedphrase/1` validator.

Legacy wallets return
`{error, {node_wallet_not_mnemonic_backed, use_private_key_export}}`.
Private-key export remains separate through
`damage_ae:export_node_wallet_for_superhero/0`; older `aeser_api_encoder`
versions without `account_seckey` support return
`{error, account_seckey_encoding_unavailable}` rather than inventing an encoding.

There is no new HTTP route, BDD step, role bypass, automatic transfer, or
identity rotation. Export requires a cached node password or the existing
`DAMAGE_SECRET_KEY` environment-password mechanism. Clearing the cache does not
revoke an environment password; that existing unlock source remains available.

## Secret handling and storage

The reverted scoped/bound encryption APIs, deletion APIs, safe ETF decoding,
template existing-atom lookup, non-caching encryption callbacks and structure-only
logging are restored. The unrelated paying-for submission lock and original
submission/confirmation behavior are restored as well.

First-run creation ensures the parent directory exists, refuses to overwrite an
existing file, sets mode 0600 before writing any content, syncs the file, and
reports filesystem failures as errors. The parent directory must be controlled
by the node operator. This is not a filesystem transaction or a replacement
for durable, tested off-host backups.

`format_status/1` redacts diagnostic state, messages, reasons and logged debug
entries. The hot-upgrade callback drops recovery/plaintext fields left by the
reviewed implementation. Prefer a controlled restart after deploying both core
modules together, then verify the node address is unchanged.

The existing password-encryption format and its HKDF derivation are preserved
for compatibility. This patch is not a password-KDF migration or a full audit of
other modules. BIP-39's mandated PBKDF2 operation is a separate derivation stage.

The BEAM/OS operator remains a trusted principal: code with arbitrary execution,
an Erlang distribution cookie, tracing/debug access, process dumps, or access
to an unlocked shell can access private material. Do not enable live tracing
of secrets or export calls, print recovery phrases into CI logs, attach them to
BDD contexts/reports, or paste them into support conversations. Status redaction
does not provide a sandbox against trusted code or guarantee memory zeroization.

## Dependencies and packaging

Use OTP 25 or later for `gen_server:format_status/1`, with working OTP `crypto`,
`enacl:sign_seed_keypair/1` and the existing `aeser_api_encoder`. The tests also
use the project's existing `jsx` JSON decoder.

No new runtime `ebip39` dependency is required by this implementation. Its
replacement is a small strict English BIP-39 codec using OTP cryptographic
primitives, plus a bundled digest-checked interoperability wordlist. Do not
remove an existing dependency if another application uses it.

Include `apps/damage/priv/bip39/english.txt` in every packaged release.
`code:priv_dir(damage)` must resolve normally. The loader checks the SHA-256 of
the exact LF-terminated bytes; it never downloads a list or falls back to an
unverified dictionary. Provenance and the digest are recorded beside the list.

## Tests

From the repository root, in a fresh development/test VM, not a running node:

```sh
rebar3 eunit --module=damage_ae_wallet_tests,secrets_wallet_tests
node scripts/verify-wallet-vectors.mjs
```

Rebar3 EUnit defines `TEST` and discovers the application `test/` directories.
Explicit-path keystore helpers and derivation primitives are exported only in
that test build. No test creates a production gproc registration, opens
`/var/lib/damage/damage.dets`, calls an AE node, or sends a transaction.

There are 19 wallet cases and 13 keystore/secret-handling cases, with multiple
assertions and sub-vectors per case. The wallet suite includes published BIP-39
and SLIP-0010 vectors, four independently checked AEX-10 addresses, real NaCl
signing, generation/restore equality, invalid phrase/checksum/type checks,
forged signing seeds, unrelated phrases, metadata mismatch, wordlist integrity,
and legacy/private-key encoder compatibility.

The keystore suite uses real OTP servers with temporary files and covers
first-run creation, mode 0600, encrypted persistence, process restart,
wrong passwords, malformed keystores, failure without overwrite, recovery-root
isolation, swapped-file rejection, repeated encryption/decryption callback
shapes, safe ETF decoding, retained API exports, and diagnostic/log redaction.
The restored scoped/bound API test checks their export contract; it does not
claim a new end-to-end DETS isolation test.

Temporary-keystore tests restore `application:get_env(damage, keystore)` and
`DAMAGE_SECRET_KEY` after each case. Do not run them in parallel with other
suites that modify those same global settings. Root directories are temporary
and mode 0700; test-created files are removed during cleanup.

`wallet_vectors.json` contains public fixtures, not operational wallet data.
They were generated independently with Python hashlib/hmac/cryptography and
cross-checked with Node.js built-in crypto. The Node verifier has no npm or
network dependency and does not execute the Erlang implementation. The
`independent_aex10_addresses` EUnit case is what checks Erlang against them.

## Verification status at patch preparation

The independent Python and Node fixture checks passed. Patch application and
whitespace checks are recorded in the distribution's verification notes.
Erlang/rebar3 are not installed in the preparation environment, so compilation
and EUnit execution have not been performed. A Superhero UI restore has not
been performed. These remain required local acceptance checks.

## References

- BIP-39: https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki
- English list: https://raw.githubusercontent.com/bitcoin/bips/master/bip-0039/english.txt
- BIP-39 vectors: https://github.com/trezor/python-mnemonic/blob/master/vectors.json
- SLIP-0010 and vectors: https://github.com/satoshilabs/slips/blob/master/slip-0010.md
- AEX-10: https://github.com/aeternity/AEXs/blob/master/AEXS/aex-10.md
- OTP status redaction: https://www.erlang.org/doc/apps/stdlib/gen_server.html#format_status/1
- enacl signing API: https://hexdocs.pm/enacl/enacl.html
- Rebar3 EUnit: https://rebar3.org/docs/testing/eunit/
