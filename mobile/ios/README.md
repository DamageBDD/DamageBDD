# DamageBDD + ECAI iOS dual-app skeleton

One Xcode project, two independent iOS application targets, two schemes, two bundle identifiers, and two Home Screen launchers:

| Target | Bundle identifier | Launcher | Included UI |
|---|---|---|---|
| `DamageBDD` | `com.damagebdd.mobile` | DamageBDD | Damage account sign-in, Gherkin feature execution, raw result output, account balance |
| `ECAI` | `com.ecai.mobile` | ECAI | Independent ECAI sign-in shell and chat |

The apps share dependency-free networking and Keychain helpers under `Shared/`, but do not compile each other's feature or app-entry files. Keychain records are automatically namespaced by each target's bundle identifier, so DamageBDD and ECAI credentials remain separate.

## Open and run

1. Open `DamageMobile.xcodeproj` in Xcode 16 or later.
2. Select the `DamageBDD` scheme to run the DamageBDD launcher.
3. Select the `ECAI` scheme to run the ECAI launcher.
4. Set a development team under **Signing & Capabilities** for both app targets.
5. Change either bundle identifier if it conflicts with an identifier registered to another Apple developer account.
6. Build for an iOS 16+ simulator or device.

Installing both targets produces two separate `.app` bundles and two icons on the device. Archiving must be done once per scheme.

## Configuration

Edit `Shared/Config/AppConfig.swift`.

### DamageBDD

Set `damageBaseURL` to the target DamageBDD node. The starter uses:

- `POST /accounts/auth/` with `username` and `password`.
- `PUT /execute_feature/` with a bearer token and JSON fields `feature`, `concurrency`, and `stream`.
- `GET /accounts/balance` with the same bearer token.

### ECAI

No production ECAI API contract was supplied, so the ECAI target is explicit about being a replaceable skeleton:

- `ecaiBaseURL == nil` enables local stub authentication and stub chat.
- Set `ecaiBaseURL`, `ecaiAuthPath`, and `ecaiChatPath` when the service contract is ready.
- `HTTPECAIAuthService` currently sends `{ "username": "...", "password": "..." }` and accepts `access_token`, `token`, or `session_token`.
- `HTTPECAIService` currently sends `{ "message": "..." }` and accepts the first non-empty string under `message`, `reply`, `content`, or `response`.
- Adapt those two HTTP adapters to the final ECAI schema before production use.

The ECAI app never reads or forwards the DamageBDD access token.

## Directory layout

```text
DamageMobileIOSDualApp/
├── DamageMobile.xcodeproj/
│   └── xcshareddata/xcschemes/
│       ├── DamageBDD.xcscheme
│       └── ECAI.xcscheme
├── Shared/
│   ├── Config/
│   ├── Networking/
│   └── Security/
├── DamageBDD/
│   ├── App/
│   ├── Features/
│   ├── Models/
│   └── Resources/
├── ECAI/
│   ├── App/
│   ├── Features/
│   ├── Models/
│   └── Resources/
├── DamageBDDTests/
├── ECAITests/
├── project.yml
└── README.md
```

## Suggested next additions

- Replace the placeholder app icons with production DamageBDD and ECAI artwork.
- Add feature import/export through Files and iCloud Drive.
- Render structured run reports rather than raw JSON.
- Add ECAI streaming over SSE or WebSocket after its transport contract is fixed.
- Add biometric gating for locally stored sessions.
- Add associated domains or shared Keychain access groups only if deliberate cross-app sign-on is later required.
