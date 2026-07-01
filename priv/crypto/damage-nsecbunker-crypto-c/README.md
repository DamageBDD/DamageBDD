# damage-nsecbunker-crypto-c

C port executable for the Damage nsecbunker Phase 2B crypto boundary.

## Build

```sh
make
```

Dependencies:

```sh
# Arch
sudo pacman -S --needed base-devel openssl pkgconf
```

## Contract

The program reads one JSON object from stdin and writes one JSON envelope to stdout.

Success:

```json
{"ok":true,"result":{}}
```

Failure:

```json
{"ok":false,"error":"reason"}
```

## Required environment

Identity/vault operations require:

```sh
export DAMAGE_NSECBUNKER_VAULT_PASSPHRASE='long local test passphrase'
```

Phase 2B NIP-44 loopback tests require:

```sh
export DAMAGE_NSECBUNKER_ALLOW_PLAIN_NIP44=1
```

## Operations

```json
{"op":"health"}
{"op":"generate_identity","vault_path":"/tmp/test.vault"}
{"op":"get_public_key","vault_path":"/tmp/test.vault"}
{"op":"npub","pubkey_hex":"<64 lowercase hex>"}
{"op":"sign_event","vault_path":"/tmp/test.vault","event":{"kind":1,"created_at":1778000000,"tags":[],"content":"test"}}
{"op":"nip44_encrypt","plaintext":"{\"id\":\"x\",\"result\":\"pong\"}"}
{"op":"nip44_decrypt","ciphertext":"plain:<base64>"}
```

## Security posture

This is still Phase 2B. It gives us a native C executable boundary and real local signing/vault mechanics, while keeping NIP-44 production encryption out of scope until vector testing is added.
