# DamageBDD + ECAI mobile skeleton

Two small, framework-free Capacitor Android applications designed for a terminal and Emacs workflow:

- `damage/`: DamageBDD account authentication, node check, and feature execution.
- `ecai/`: configurable chat client with an adapter for an ECAI HTTP endpoint.
- `shared/`: CSS and browser/native HTTP helpers copied into both applications at build time.

The generated Android projects are intentionally not included. `make init` installs JavaScript dependencies, builds `www/`, and runs `npx cap add android` for each app. Commit each generated `android/` directory after initialisation.

## Directory layout

```text
.
├── Makefile
├── common.mk
├── scripts/
│   ├── build-app.mjs
│   └── doctor.sh
├── shared/web/
│   ├── common.css
│   ├── http.js
│   ├── storage.js
│   └── ui.js
├── damage/
│   ├── capacitor.config.json
│   ├── Makefile
│   ├── package.json
│   └── src/
└── ecai/
    ├── capacitor.config.json
    ├── Makefile
    ├── package.json
    └── src/
```

## Arch Linux prerequisites

```sh
sudo pacman -S --needed \
  nodejs npm jdk21-openjdk android-tools android-udev \
  git curl unzip zip make python

sudo archlinux-java set java-21-openjdk
```

This project assumes the Android SDK is either selected with `ANDROID_HOME` / `ANDROID_SDK_ROOT` or installed at `/opt/android-sdk`.

For the SDK shown in the earlier Gradle output:

```sh
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"

sudo env JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
  "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
  --sdk_root="$ANDROID_HOME" \
  'build-tools;35.0.0' 'platforms;android-36' 'platform-tools'

yes | sudo env JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
  "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
  --sdk_root="$ANDROID_HOME" --licenses
```

Check the environment:

```sh
make doctor
```

## Initialise both applications

```sh
make init
```

This runs `npm install`, creates each `www/` directory, generates the native Android project, and synchronises Capacitor.

Initialise only one app:

```sh
make init-damage
make init-ecai
```

## Build and run

Connect a phone with USB debugging enabled and accept its RSA prompt:

```sh
adb devices
```

Then run either application:

```sh
make run-damage
make run-ecai
```

Build both without installing:

```sh
make build
```

For multiple devices:

```sh
make run-damage DEVICE_SERIAL=YOUR_DEVICE_SERIAL
```

From inside either app directory, the same operations are available as `make init`, `make run`, `make log`, and `make clean`.

## Emacs workflow

Open the source, not generated `www/` files:

```sh
emacs damage/src/app.js damage/src/index.html
```

From Emacs:

```text
M-x compile RET make run-damage RET
```

The web build is only a deterministic copy step; there is no bundler or framework. Common files from `shared/web/` are copied into `www/shared/`.

## DamageBDD API wiring

The Damage app uses these existing server contracts:

```text
GET  /version/
POST /accounts/auth/
PUT  /execute_feature/
```

Authentication request:

```json
{
  "username": "person@example.com",
  "password": "password"
}
```

Feature execution request:

```json
{
  "feature": "Feature: ...",
  "concurrency": 1,
  "stream": false
}
```

The access token is sent as:

```text
Authorization: Bearer TOKEN
```

`CapacitorHttp` native `fetch` patching is enabled in each `capacitor.config.json`, so packaged Android requests use the native HTTP stack. A browser preview still requires normal server CORS headers.

## ECAI API adapter

No ECAI server contract was supplied, so the skeleton deliberately keeps it isolated in `ecai/src/api.js`.

The default request is OpenAI-style but vendor-neutral:

```json
{
  "messages": [
    {"role": "user", "content": "Hello"}
  ],
  "stream": false
}
```

When a model is configured, a `model` property is included. The response adapter understands common shapes such as:

```text
reply
response
output_text
message.content
choices[0].message.content
```

Change only `ecai/src/api.js` when the real ECAI API contract is known.

## Security boundary

This is a development skeleton:

- Passwords are never stored.
- Bearer tokens are kept in `sessionStorage`, not `localStorage`.
- Server URLs and non-secret UI settings use `localStorage`.
- Production wallet, NWC, Nostr, or long-lived credentials should move behind Android Keystore through a small native Capacitor plugin.
- Use HTTPS endpoints. Do not enable Android cleartext traffic for production.

## App identifiers

Set these before the first `make init` if different identifiers are required:

```text
DamageBDD: com.damagebdd.app
ECAI:      com.ecai.app
```

Update both the app's `capacitor.config.json` and `APP_ID` in its `Makefile`.
