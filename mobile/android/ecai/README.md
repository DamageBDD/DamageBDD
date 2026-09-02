# ECAI mobile

A framework-free chat shell with a configurable base URL, path, model, and optional bearer token.

```sh
make init
make run
make log
```

The unknown server-specific contract is isolated in `src/api.js`. Adjust `sendChat()` and `extractAssistantText()` when the ECAI API is defined.

The bearer token and chat transcript are session-only in this skeleton.
