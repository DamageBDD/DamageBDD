# DamageBDD Android client

Framework-free Capacitor client for DamageBDD authentication, wallet balances,
Nostr Wallet Connect session creation, and Gherkin feature execution.

## Navigation

The application has four primary screens:

- **Home** — Lightning, AE, and DAMAGE balances plus quick actions.
- **Run** — Gherkin editor, execution controls, and the latest run report.
- **Wallet** — account login, signed AE wallet login, wallet address, and NWC sessions.
- **Settings** — DamageBDD node selection and node health/version check.

## API contracts

```text
GET  /version/
POST /accounts/auth/
GET  /accounts/wallet
GET  /accounts/balance          # compatibility fallback
POST /api/nwc/sessions
POST /api/nwc/mint
POST /api/nwc/revoke            # API adapter available for future session management
PUT  /execute_feature/
```

`GET /accounts/wallet` is the preferred balance endpoint. It returns atomic
amounts as strings so JavaScript does not lose integer precision:

```json
{
  "status": "ok",
  "address": "ak_...",
  "updated_at": 1788400000,
  "balances": {
    "lightning": {
      "available": true,
      "amount": "12504000",
      "amount_msat": "12504000",
      "amount_sat": "12504",
      "decimals": 3,
      "symbol": "sat",
      "source": "nwc_ledger",
      "session_count": 2
    },
    "ae": {
      "available": true,
      "amount": "4200000000000000000",
      "decimals": 18,
      "symbol": "AE",
      "source": "aeternity_node"
    },
    "damage": {
      "available": true,
      "amount": "1200000000",
      "decimals": 8,
      "symbol": "DAMAGE",
      "source": "damage_token"
    }
  }
}
```

When a node has not yet added `/accounts/wallet`, the app falls back to
`/accounts/balance` plus `/api/nwc/sessions`. It recognises the current atomic
and display fields for Lightning, AE, and DAMAGE and marks any balance the older
node does not expose as unavailable. Upgrade the node to `/accounts/wallet` for
a single consistent, lossless snapshot.

## Authentication

### DamageBDD account

```json
{
  "username": "person@example.com",
  "password": "..."
}
```

### Signed AE wallet

The app creates a five-minute JSON message containing the selected node,
address, nonce, issue time, and expiry time. The user signs the exact text in an
AE wallet, then submits:

```json
{
  "address": "ak_...",
  "signature": "...",
  "meta": "{...exact signed message...}"
}
```

The private key never enters the DamageBDD application. This client uses the
existing DamageBDD signed-message authentication contract; a future native
wallet connector can replace the copy/sign/paste interaction without changing
the server request.

## Build

Edit files under `src/`. The `www/` directory is generated.

```bash
cd mobile/android/damage
npm ci
npm run web
npx cap sync android
cd android
./gradlew assembleDebug
```

From `mobile/`, the normal terminal workflow is:

```bash
make run-damage
```

## Security boundary

- Passwords, wallet signatures, and generated NWC URIs are not persisted.
- The bearer token remains in `sessionStorage` for this development client.
- Server URL and Gherkin draft are the only persistent preferences.
- NWC URIs contain a secret and must be handled like passwords.
- Move bearer credentials behind Android Keystore before enabling long-lived
  sessions.
- Use HTTPS DamageBDD nodes in production.
