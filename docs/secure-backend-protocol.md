# Secure backend protocol

The production crypto backend is a long-lived process. It is started without a
passphrase in its arguments or environment. Standard input and output use
Erlang's `{packet, 4}` framing.

## Frames

| Direction | Type byte | Payload |
|---|---:|---|
| Erlang → C | `0x01` | raw passphrase bytes |
| C → Erlang | `0x81 0x00` | unlock acknowledged |
| C → Erlang | `0x81 0x01` | safe machine error code |
| Erlang → C | `0x02` | UTF-8 JSON operation |
| C → Erlang | `0x82 0x00` | UTF-8 JSON response |
| C → Erlang | `0x82 0x01` | safe machine error code |

The backend must:

1. Accept exactly one unlock frame per process lifetime.
2. Reject operation frames before unlock.
3. Derive or load the vault key immediately.
4. Clear the temporary passphrase buffer with a non-optimisable primitive such
   as `explicit_bzero` where available.
5. Never echo, log, crash-dump, or include the passphrase in an error response.
6. Retain only the unlocked key state required for operations.
7. Exit if the controlling stdin closes or the protocol is malformed.

The service supervisor treats any backend exit as a sealed-vault condition and
restarts the complete secret-owner/backend unit. There is no local, file,
interactive, or environment fallback in production.
