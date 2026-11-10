# ECAI Flow: install Flutter and build Android / iOS

Prepared for the ECAI Flow v0.1.0 client at `clients/ecai_flow`.
The workflow is a native **build-check and test-artifact pipeline**, not a store
release pipeline. It does not deploy the ECAI/Damage backend.

## Install the workflow

From the DamageBDD repository root, after extracting this bundle:

```bash
mkdir -p .github/workflows docs/ecai
install -m 644 "$HOME/Downloads/ecai-flow-mobile-ci/.github/workflows/ecai-flow-mobile.yml" \
  .github/workflows/ecai-flow-mobile.yml
install -m 644 "$HOME/Downloads/ecai-flow-mobile-ci/docs/ecai/FLUTTER_MOBILE_BUILDS.md" \
  docs/ecai/FLUTTER_MOBILE_BUILDS.md
```

Alternatively, download just `ecai-flow-mobile.yml` and copy it to
`.github/workflows/ecai-flow-mobile.yml`. There are no new helper-script dependencies:
the workflow uses the `tool/bootstrap.py` already included in v0.1.0.

Apply the included two-line compatibility patch to the original v0.1.0 client:

```bash
PATCH="$HOME/Downloads/ecai-flow-mobile-ci/ecai-flow-flutter-compat.patch"
git apply --check "$PATCH" && git apply "$PATCH"
```

It replaces the deprecated `DropdownButtonFormField.value` argument with
`initialValue`, and removes a redundant `dart:async` import. No analyzer rules
are weakened. If you have already made those edits, do not apply the patch again.
Other source changes may require rebasing these two edits manually.

In GitHub, open **Settings > Secrets and variables > Actions > Variables**.
Create a **repository variable** named `FLOW_API_URL` with your public HTTPS API
endpoint, including `/ecai/flow/v1`, for example:

```text
https://YOUR_HOST/ecai/flow/v1
```

Replace `YOUR_HOST`. Never put credentials, bearer tokens, or API keys in this
value. The URL is compiled into the app and included in build metadata.
The initial client connects anonymously to the sandbox API and receives a
session token at runtime; this workflow does not provision a production login.

For manual runs, `flow_api_url` overrides the repository variable. Without either
setting, CI uses `https://example.invalid/ecai/flow/v1`, warns, and still compiles.
Such an artifact cannot connect to a backend. Set the real URL and rebuild to
change it; v0.1.0 does not include a runtime endpoint editor.

```bash
git add .github/workflows/ecai-flow-mobile.yml \
  clients/ecai_flow/lib/flow_api.dart clients/ecai_flow/lib/flow_app.dart
# Add documentation even in repositories that ignore Markdown globally:
git add -f docs/ecai/FLUTTER_MOBILE_BUILDS.md
git commit -m "ci(ecai-flow): build Android and iOS test artifacts"
git push
```

Changes to the client or workflow trigger builds on `main`, `master`, and
`develop`, and on pull requests. A manual run is also available under Actions
once the workflow exists on the repository's default branch. The job requires
GitHub-hosted runners and access to dependency downloads. Organization policy
must permit the referenced actions, including `subosito/flutter-action`.

## 1. Install the local Flutter SDK

The workflow pins **Flutter 3.47.5**. Use the same SDK locally rather than a
floating channel. Change the workflow pin deliberately when upgrading.
Flutter provides its own matching Dart SDK; do not install a separate Dart SDK
for this project.

### Arch Linux workstation

```bash
sudo pacman -Syu --needed git curl unzip xz zip glu python jdk17-openjdk
mkdir -p "$HOME/develop"
git clone --depth 1 --branch 3.47.5 \
  https://github.com/flutter/flutter.git "$HOME/develop/flutter"
export PATH="$HOME/develop/flutter/bin:$PATH"
flutter --version
```

The clone command expects `~/develop/flutter` not to exist. Preserve any existing
SDK rather than deleting it. To use a separate install, choose a different folder
and adjust PATH accordingly. Do not run Flutter itself with sudo.

Persist the PATH in your shell's startup configuration. For Zsh:

```bash
echo 'export PATH="$HOME/develop/flutter/bin:$PATH"' >> "$HOME/.zshrc"
```

For Bash, use `~/.bashrc` instead. Open a fresh terminal afterward.

### Ubuntu / Debian workstation

Use these prerequisites in place of the Arch package command, then use the same
SDK clone and PATH commands:

```bash
sudo apt-get update
sudo apt-get install -y git curl unzip xz-utils zip libglu1-mesa \
  python3 openjdk-17-jdk
```

### macOS workstation

Install Xcode's command-line tools, then use the same clone and PATH commands.
Install Python 3 if it is not available (`python3 --version`).

```bash
xcode-select --install
mkdir -p "$HOME/develop"
git clone --depth 1 --branch 3.47.5 \
  https://github.com/flutter/flutter.git "$HOME/develop/flutter"
export PATH="$HOME/develop/flutter/bin:$PATH"
flutter --version
```

Add the PATH to `~/.zshrc`. Full Xcode is additionally required for iOS; the
command-line tools package alone is not sufficient.

### Windows workstation

Install Git and Python 3, obtain Flutter 3.47.5 from the official SDK archive,
extract it into a user-writable location such as `C:\develop\flutter`, and add
`C:\develop\flutter\bin` to your user's PATH. Open a new terminal and run
`flutter --version` and `flutter doctor -v`. Use `python` instead of `python3`
where your Python installation requires it. Android builds work on Windows;
iOS builds still run on macOS, locally or through this workflow.

## 2. Configure Android tooling

Install Android Studio from its official download and complete the setup wizard.
Open **Tools > SDK Manager** (or **More Actions > SDK Manager** on the welcome
screen). Install the Android SDK platform required by the generated project,
Android SDK Build-Tools, Command-line Tools, Platform-Tools, and, for emulator
use, Android Emulator. Flutter's setup guide also lists NDK (Side by side) and
CMake. The generated Gradle project selects the needed SDK/NDK versions; do not
substitute arbitrary versions in the project merely to silence an error.

On Arch Linux, point Flutter at the JDK installed above:

```bash
flutter config --jdk-dir=/usr/lib/jvm/java-17-openjdk
```

On Ubuntu x86_64, the corresponding path is normally:

```bash
flutter config --jdk-dir=/usr/lib/jvm/java-17-openjdk-amd64
```

On other systems use the actual installed JDK path. CI explicitly uses Temurin
17. On Linux the Android SDK normally resides under `~/Android/Sdk`; confirm its
actual location in Android Studio before setting it:

```bash
flutter config --android-sdk="$HOME/Android/Sdk"
flutter doctor --android-licenses
flutter precache --android
flutter doctor -v
flutter devices
```

Read the licenses before accepting them. No Linux desktop, Chrome, or Windows
C++ toolchain is needed solely to build the Android client. Resolve issues in
`flutter doctor` relevant to your selected target.

## 3. Bootstrap and run the actual client

From the repository root:

```bash
cd clients/ecai_flow
python3 tool/bootstrap.py --platforms=android
flutter analyze
flutter test
flutter devices
```

The bootstrap uses `flutter create` in a temporary directory and copies only the
native host project. Do not replace it with `flutter create .`, which can add
sample application tests or alter application files.

Start an emulator using Android Studio, or connect an Android phone with USB
debugging enabled. Then:

```bash
flutter run --dart-define=FLOW_API_URL=https://YOUR_HOST/ecai/flow/v1
```

Flutter will prompt for a device when more than one is available. The URL must be
reachable by the emulator or phone, with a trusted certificate. The backend must
actually be running; it is not bundled into the mobile app.

For the existing local reference server, run this from the repository root in
another terminal:

```bash
node tools/ecai-flow/serve.mjs
```

Then from `clients/ecai_flow`, target your running Android emulator:

```bash
flutter run --dart-define=FLOW_API_URL=http://10.0.2.2:8787/ecai/flow/v1
```

This is DEBUG-only. `10.0.2.2` is the Android Emulator's alias for the host's
loopback interface, not a physical phone endpoint. Release builds and ordinary
physical-device access should use your HTTPS deployment. Do not use
`127.0.0.1:8787` as a public mobile release endpoint.

After the initial successful dependency resolution, commit the application lock:

```bash
git add pubspec.lock
git commit -m "build(ecai-flow): lock Flutter client dependencies"
```

The workflow enforces a tracked lockfile and detects changes. Without a committed
lock it resolves dependencies, warns, and includes each job's resulting lock in
its artifacts; those independently resolved initial builds are not guaranteed to
use identical dependency versions. `SHA256SUMS` provides integrity checks, not a
claim of bit-for-bit build reproducibility or authenticated provenance.

## 4. Local iOS setup (Mac only)

Install full Xcode and select it. Read and accept its license, download iOS
platform support, and install CocoaPods for native-plugin support:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
sudo xcodebuild -license
xcodebuild -downloadPlatform iOS
# With Homebrew already installed:
brew install cocoapods
flutter doctor -v
```

From the client directory:

```bash
python3 tool/bootstrap.py --platforms=ios
flutter analyze
flutter test
flutter build ios --simulator --debug --no-codesign \
  --dart-define=FLOW_API_URL=https://YOUR_HOST/ecai/flow/v1
```

Select/start a suitable simulator in Xcode, then use `flutter devices` and
`flutter run -d DEVICE_ID` with the same Dart define. Physical iPhone execution
requires appropriate signing configuration; App Store / TestFlight distribution
requires the Apple Developer Program and matching app identity / provisioning.
A Linux workstation can trigger GitHub's macOS build; it cannot execute Xcode.

## 5. Workflow behavior and artifacts

The workflow uses Ubuntu 24.04 for Android and macOS 15 for iOS, explicitly
selecting Xcode 26.3 instead of relying on an image's potentially older default.
A missing pinned Xcode fails clearly; update the pin after reviewing the runner
image, rather than silently selecting an arbitrary installation.

For each platform it validates the endpoint, prepares Flutter, bootstraps the
native host, analyzes Dart, runs the Flutter tests, compiles, and uploads artifacts.
No code-analysis or Flutter-test failures are suppressed.

| Artifact | Purpose |
| --- | --- |
| `ecai-flow-debug.apk` | Android debug testing; sideload with ADB. |
| `ecai-flow-release-test.apk` | Android release-mode testing; generated hosts still use a debug signing key. |
| `ecai-flow-release-test.aab` | Android bundle compilation check; not a store-signed bundle. |
| `ecai-flow-ios-simulator.tar.gz` | Simulator `.app`; use a compatible Mac simulator architecture/runtime. |
| `ecai-flow-ios-device-unsigned.tar.gz` | Unsigned device `.app`; compilation output, not an installable IPA. |
| `build-info.json`, `pubspec.lock`, `SHA256SUMS` | Build inputs, resolved dependencies, and file digests. |
| Separate coverage artifact | Flutter LCOV coverage, when the tests produce it. |

Download artifacts from **Actions > ECAI Flow - Android and iOS > run > Artifacts**.
They are retained for 14 days, subject to repository policy. The workflow does
not publish GitHub Releases, Play Store packages, or TestFlight uploads.

After extracting the Android artifact, for a connected device:

```bash
adb install -r ecai-flow-debug.apk
```

Hosted runners create temporary debug keys. A build from a later run may not
replace one signed by an earlier run. In that case uninstall the earlier test app
first (this deletes its local data), or adopt a controlled persistent test-signing
key in a separate protected workflow. Do not confuse debug keys with production
upload/signing keys.

For a simulator artifact, extract it on a compatible Mac, start an iOS simulator,
and install its `.app`:

```bash
mkdir -p ecai-flow-simulator
tar -xzf ecai-flow-ios-simulator.tar.gz -C ecai-flow-simulator
xcrun simctl install booted ecai-flow-simulator/Runner.app
```

Open the installed app from the simulator. The workflow builds on the selected
runner architecture; `build-info.json` records that architecture. This is not a
promise that an Apple Silicon simulator binary runs on an Intel Mac.

## 6. Before store distribution

Review and commit `android/` and `ios/` with your actual application / bundle IDs,
icons, display name, permissions, and supported versions. The v0.1.0 client ignores
these folders by design; revise `.gitignore` deliberately. Avoid blindly force-
adding all generated contents: retain platform `.gitignore` rules and never
commit `local.properties`, keystores, signing properties, certificates, or Pods.

Android store distribution requires a proper upload/release signing configuration
and your Play App Signing setup. The default generated project's release mode is
still debug-signed. iOS distribution requires the registered Bundle ID, Apple
team, certificate/private key and provisioning configuration, followed by a
proper `flutter build ipa` export. Packaging an unsigned `.app` into a `.zip` and
renaming it `.ipa` does not provide signing or make it installable.

Use a separately protected release workflow with approved branches/tags and a
protected GitHub Environment for any signing secrets. Keep fork pull-request
builds secret-free. Pin third-party and first-party actions to reviewed full
commit SHAs before adding sensitive signing authority; this initial build-check
workflow uses maintained major action tags and read-only repository permission.

## Validation scope

This delivery checks YAML parsing, workflow structural invariants, embedded Bash
syntax, embedded Python syntax, endpoint validation, and mocked artifact handling.
Flutter, Xcode, Android SDK, actionlint and GitHub runner execution were not
available in the authoring environment. This is **not** a claim that native builds
or the existing Dart tests have passed. GitHub Actions runs those checks on the
actual toolchains and fails on errors.

## Primary references (checked November 10, 2026)

- Dropdown compatibility: https://api.flutter.dev/flutter/material/DropdownButtonFormField/DropdownButtonFormField.html
- Dart async imports: https://dart.dev/libraries/dart-async
- Flutter installation: https://docs.flutter.dev/install/manual
- Flutter SDK archive: https://docs.flutter.dev/install/archive
- Flutter Git-based setup: https://docs.flutter.dev/deployment/cd
- Android setup: https://docs.flutter.dev/platform-integration/android/setup
- iOS setup: https://docs.flutter.dev/platform-integration/ios/setup
- Android signing/builds: https://docs.flutter.dev/deployment/android
- iOS distribution: https://docs.flutter.dev/deployment/ios
- Flutter Android template: https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/templates/app/android-kotlin.tmpl/app/build.gradle.kts.tmpl
- Emulator networking: https://developer.android.com/studio/run/emulator-networking
- Flutter Action: https://github.com/subosito/flutter-action
- Checkout Action: https://github.com/actions/checkout
- Java Action: https://github.com/actions/setup-java
- Artifact Action: https://github.com/actions/upload-artifact
- Hosted images: https://github.com/actions/runner-images
- macOS 15 image: https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md
- GitHub Actions security: https://docs.github.com/en/actions/reference/security/secure-use
