# DamageBDD Mobile — Build and Publish Guide

This document describes how to build, test, sign, collect, and publish the mobile artifacts for the two applications in this repository:

- **DamageBDD** — Android package `com.damagebdd.app`
- **ECAI** — Android package `com.ecai.app`

The mobile workspace is expected to have this shape:

```text
mobile/
├── Makefile
├── android/
│   ├── Makefile
│   ├── common.mk
│   ├── damage/
│   ├── ecai/
│   ├── scripts/
│   └── shared/
└── ios/
    ├── DamageBDD/
    ├── DamageBDDTests/
    ├── DamageMobile.xcodeproj
    ├── ECAI/
    ├── ECAITests/
    ├── Shared/
    └── project.yml
```

The top-level `mobile/Makefile` is the entry point for normal local builds. Android is the default workflow on Linux/Arch; iOS builds require macOS and Xcode.

---

## 1. Prerequisites

### Android / Arch Linux

Install the host tools:

```bash
sudo pacman -S --needed \
    nodejs \
    npm \
    jdk21-openjdk \
    android-tools \
    android-udev \
    git \
    curl \
    unzip \
    zip \
    make
```

Select Java 21 if required:

```bash
archlinux-java status
sudo archlinux-java set java-21-openjdk
```

The Android SDK used by the project must include:

```text
platform-tools
platforms;android-36
build-tools;35.0.0
```

For a system SDK under `/opt/android-sdk`:

```bash
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
```

Accept the SDK licences:

```bash
yes | sudo env JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
    "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
    --sdk_root="$ANDROID_HOME" \
    --licenses
```

Install the required SDK components:

```bash
sudo env JAVA_HOME=/usr/lib/jvm/java-21-openjdk \
    "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
    --sdk_root="$ANDROID_HOME" \
    "platform-tools" \
    "platforms;android-36" \
    "build-tools;35.0.0"
```

Verify the environment:

```bash
java -version
node --version
npm --version
adb version
sdkmanager --version
```

### iOS

iOS builds require:

- macOS
- Xcode
- Xcode command-line tools
- XcodeGen if regenerating the project from `ios/project.yml`

Check:

```bash
xcodebuild -version
xcodegen --version
```

---

## 2. First-time setup

From the repository root:

```bash
cd mobile
make doctor
make init
```

`make init` delegates to the Android workspace and installs/synchronises the Capacitor projects.

The explicit Android form is:

```bash
make android-doctor
make android-init
```

If the generated native Android projects are not present, the Capacitor setup in each application must be created before the first Gradle build.

---

## 3. Local Android development builds

Build both applications:

```bash
cd mobile
make android-build
```

or use the Android-default alias:

```bash
make build
```

Build one application:

```bash
make android-build-damage
make android-build-ecai
```

Short aliases:

```bash
make build-damage
make build-ecai
```

### Run on a connected Android device

Enable USB debugging on the phone, then check:

```bash
adb devices
```

Run DamageBDD:

```bash
make run-damage
```

Run ECAI:

```bash
make run-ecai
```

When several devices are attached:

```bash
make run-damage DEVICE_SERIAL=<serial>
make run-ecai DEVICE_SERIAL=<serial>
```

### Debug APK paths

A normal Capacitor/Gradle debug build produces:

```text
mobile/android/damage/android/app/build/outputs/apk/debug/app-debug.apk
mobile/android/ecai/android/app/build/outputs/apk/debug/app-debug.apk
```

Install one manually with:

```bash
adb install -r \
    android/damage/android/app/build/outputs/apk/debug/app-debug.apk
```

or:

```bash
adb install -r \
    android/ecai/android/app/build/outputs/apk/debug/app-debug.apk
```

Debug APKs are development/test artifacts. Do not upload a debug APK as the production Play Store release.

---

## 4. GitHub Actions Android builds

The repository workflow is expected at:

```text
.github/workflows/android.yml
```

It runs when files under:

```text
mobile/android/**
```

change on a push or pull request. It can also be started manually with `workflow_dispatch`.

The CI matrix builds both applications:

```text
DamageBDD -> damagebdd-debug-<git-sha>
ECAI      -> ecai-debug-<git-sha>
```

Each artifact contains its corresponding `app-debug.apk`.

The workflow uses:

```text
Node          22
Java          21
Android API   36
Build Tools   35.0.0
```

### Required lockfiles

CI uses `npm ci`, so commit each application's lockfile:

```bash
git add \
    mobile/android/damage/package-lock.json \
    mobile/android/ecai/package-lock.json
```

### Download artifacts from the GitHub UI

1. Open the repository on GitHub.
2. Open **Actions**.
3. Select **Android CI**.
4. Select the required workflow run.
5. Download the `damagebdd-debug-*` or `ecai-debug-*` artifact.

### Download artifacts with `gh`

List recent workflow runs:

```bash
gh run list --workflow android.yml
```

Inspect a run:

```bash
gh run view <run-id>
```

Download all artifacts:

```bash
mkdir -p dist/ci
gh run download <run-id> --dir dist/ci
```

Or download a single artifact:

```bash
gh run download <run-id> \
    --name "damagebdd-debug-<git-sha>" \
    --dir dist/ci/damagebdd
```

GitHub Actions artifacts are intended for test/review distribution. The workflow currently builds **debug APKs**, not Play Store release bundles.

---

## 5. Android release artifacts

Google Play releases should be uploaded as signed Android App Bundles (`.aab`).

The release flow is:

```text
web assets
    ↓
Capacitor sync
    ↓
Gradle bundleRelease
    ↓
unsigned/release AAB
    ↓
upload-key signature
    ↓
verified signed AAB
    ↓
Play Console
```

Keep signing keys outside the repository.

### Create upload keystores

Create a private directory:

```bash
mkdir -p "$HOME/.android/keystores"
chmod 700 "$HOME/.android/keystores"
```

DamageBDD:

```bash
keytool -genkeypair \
    -keystore "$HOME/.android/keystores/damagebdd-upload.jks" \
    -alias damagebdd-upload \
    -keyalg RSA \
    -keysize 4096 \
    -validity 10000
```

ECAI:

```bash
keytool -genkeypair \
    -keystore "$HOME/.android/keystores/ecai-upload.jks" \
    -alias ecai-upload \
    -keyalg RSA \
    -keysize 4096 \
    -validity 10000
```

Back up both keystores securely. Never commit them.

Recommended `.gitignore` entries:

```gitignore
*.jks
*.keystore
dist/
.build/
```

---

## 6. Build unsigned release AABs

Build/synchronise the web application first.

### DamageBDD

```bash
cd mobile/android/damage

npm ci
npm run web
npx cap sync android

cd android
./gradlew --no-daemon bundleRelease
```

Input bundle:

```text
mobile/android/damage/android/app/build/outputs/bundle/release/app-release.aab
```

### ECAI

```bash
cd mobile/android/ecai

npm ci
npm run web
npx cap sync android

cd android
./gradlew --no-daemon bundleRelease
```

Input bundle:

```text
mobile/android/ecai/android/app/build/outputs/bundle/release/app-release.aab
```

---

## 7. Sign release AABs

Create a release directory:

```bash
cd mobile
mkdir -p dist/android
```

### DamageBDD

```bash
jarsigner \
    -verbose \
    -sigalg SHA256withRSA \
    -digestalg SHA-256 \
    -keystore "$HOME/.android/keystores/damagebdd-upload.jks" \
    -signedjar dist/android/damagebdd-release.aab \
    android/damage/android/app/build/outputs/bundle/release/app-release.aab \
    damagebdd-upload
```

### ECAI

```bash
jarsigner \
    -verbose \
    -sigalg SHA256withRSA \
    -digestalg SHA-256 \
    -keystore "$HOME/.android/keystores/ecai-upload.jks" \
    -signedjar dist/android/ecai-release.aab \
    android/ecai/android/app/build/outputs/bundle/release/app-release.aab \
    ecai-upload
```

`jarsigner` will ask for the keystore password interactively. This is preferable to putting signing passwords in the command line, repository, or shell history.

---

## 8. Verify signed AABs

Always verify before publishing:

```bash
jarsigner -verify -verbose -certs \
    dist/android/damagebdd-release.aab

jarsigner -verify -verbose -certs \
    dist/android/ecai-release.aab
```

The expected output must report that the JAR/AAB is verified.

Optionally export the public upload certificates:

```bash
keytool -exportcert -rfc \
    -keystore "$HOME/.android/keystores/damagebdd-upload.jks" \
    -alias damagebdd-upload \
    -file dist/android/damagebdd-upload-cert.pem

keytool -exportcert -rfc \
    -keystore "$HOME/.android/keystores/ecai-upload.jks" \
    -alias ecai-upload \
    -file dist/android/ecai-upload-cert.pem
```

Expected release directory:

```text
mobile/dist/android/
├── damagebdd-release.aab
├── ecai-release.aab
├── damagebdd-upload-cert.pem
└── ecai-upload-cert.pem
```

---

## 9. Versioning before release

Every Play Store update requires a new Android `versionCode`.

Before producing a new release, update the version information for the relevant application.

Typical Gradle configuration:

```gradle
defaultConfig {
    applicationId "com.damagebdd.app"
    versionCode 2
    versionName "0.1.1"
}
```

ECAI uses its own package/application ID and version sequence.

A practical release convention is:

```text
versionName = user-facing semantic version
versionCode = monotonically increasing integer
```

For example:

```text
0.1.0 -> versionCode 1
0.1.1 -> versionCode 2
0.2.0 -> versionCode 3
```

Do not reuse a previously published `versionCode`.

---

## 10. Publish Android artifacts to Google Play

DamageBDD and ECAI are separate Play Console applications.

Expected package identities:

```text
DamageBDD  com.damagebdd.app
ECAI       com.ecai.app
```

### First release

For each application:

1. Create the application in Google Play Console.
2. Enable/use Play App Signing.
3. Complete the app access, content, privacy, and Data Safety declarations.
4. Add the store listing:
   - application name
   - short description
   - full description
   - icon
   - feature graphic
   - phone/tablet screenshots as applicable
   - privacy-policy URL
5. Configure tester access if authentication is required.
6. Open **Testing → Internal testing**.
7. Create a release.
8. Upload the corresponding signed `.aab`.
9. Resolve all Play Console validation errors/warnings.
10. Roll the release out to internal testers.

Use:

```text
dist/android/damagebdd-release.aab
```

for DamageBDD and:

```text
dist/android/ecai-release.aab
```

for ECAI.

Test the Play-distributed build before promoting it to a wider track.

### Promotion path

A sensible release progression is:

```text
local debug
    ↓
GitHub Actions debug APK
    ↓
Play Internal Testing
    ↓
Play Closed/Open Testing as required
    ↓
Production
```

Do not treat a locally installed debug APK as proof that the Play-distributed build is correct. Test authentication, API connectivity, feature execution/chat, deep links, permissions, and upgrades using a build installed from the Play testing track.

---

## 11. Publish release artifacts to GitHub

A signed `.aab` can also be attached to a GitHub Release for build archival.

Create a version tag:

```bash
git tag -a v0.1.0 -m "Mobile v0.1.0"
git push origin v0.1.0
```

Create a GitHub Release and attach both bundles:

```bash
gh release create v0.1.0 \
    dist/android/damagebdd-release.aab \
    dist/android/ecai-release.aab \
    --title "Mobile v0.1.0" \
    --generate-notes
```

An `.aab` is a Play Store distribution artifact, not normally something an Android user installs directly. Use debug/release APKs for direct device installation and AABs for Play publishing.

Do **not** attach:

```text
*.jks
*.keystore
private signing keys
keystore passwords
```

to a GitHub Release.

---

## 12. iOS local builds

iOS operations must be run on macOS.

From `mobile/`:

```bash
make ios-doctor
make ios-list
```

Regenerate the Xcode project from `ios/project.yml` when necessary:

```bash
make ios-generate
```

Build both schemes:

```bash
make ios-build
```

Build individually:

```bash
make ios-build-damage
make ios-build-ecai
```

The schemes are:

```text
DamageBDD
ECAI
```

The default Makefile builds against:

```text
generic/platform=iOS Simulator
```

and stores derived data under:

```text
mobile/.build/ios/
```

These are development builds, not App Store archives.

---

## 13. iOS archive and App Store/TestFlight publishing

A publishable iOS build requires Apple signing, a development team, bundle identifiers, and suitable provisioning.

A typical archive command for DamageBDD is:

```bash
cd mobile

xcodebuild \
    -project ios/DamageMobile.xcodeproj \
    -scheme DamageBDD \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$PWD/dist/ios/DamageBDD.xcarchive" \
    -allowProvisioningUpdates \
    archive
```

For ECAI:

```bash
xcodebuild \
    -project ios/DamageMobile.xcodeproj \
    -scheme ECAI \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$PWD/dist/ios/ECAI.xcarchive" \
    -allowProvisioningUpdates \
    archive
```

Exporting the archive requires an `ExportOptions.plist` appropriate for the Apple account/team and distribution method:

```bash
xcodebuild \
    -exportArchive \
    -archivePath "$PWD/dist/ios/DamageBDD.xcarchive" \
    -exportOptionsPlist ExportOptions.plist \
    -exportPath "$PWD/dist/ios/DamageBDD" \
    -allowProvisioningUpdates
```

Repeat for ECAI.

Upload the resulting archive/export using the Apple-supported App Store Connect workflow. Signing and provisioning should be tested independently for both schemes because they are separate applications.

---

## 14. Cleaning builds

Clean both platforms from the top-level mobile workspace:

```bash
make clean
```

Android only:

```bash
make android-clean
```

iOS derived data only:

```bash
make ios-clean
```

For a completely fresh Android Capacitor build, remove generated output only after confirming that no native customisations would be lost.

---

## 15. Release checklist

Before publishing a mobile release:

```text
[ ] repository is clean
[ ] correct branch/commit is checked out
[ ] npm lockfiles are committed
[ ] Android SDK/JDK versions are correct
[ ] local Android debug build passes
[ ] GitHub Android CI passes
[ ] DamageBDD authentication works
[ ] DamageBDD feature execution works
[ ] ECAI chat works against the intended API
[ ] application IDs are correct
[ ] versionCode/versionName are updated
[ ] release AABs were rebuilt from the intended commit
[ ] AAB signatures verify successfully
[ ] signing keys are not inside the repository
[ ] privacy/Data Safety declarations match actual behaviour
[ ] reviewer/test credentials are valid where required
[ ] Play Internal Testing installation has been tested
[ ] release tag matches the published binaries
```

For iOS additionally:

```text
[ ] archive uses Release configuration
[ ] correct Apple team is selected
[ ] correct bundle identifiers are selected
[ ] archive signing validates
[ ] TestFlight build installs and launches
```

---

## 16. Recommended artifact policy

Keep the different artifact classes clearly separated:

| Artifact | Purpose | Signing | Retention |
| --- | --- | --- | --- |
| Debug APK | local/CI testing | debug key | short-lived |
| Signed AAB | Google Play | upload key | permanent release artifact |
| Upload certificate | Play key registration/recovery support | public certificate | permanent |
| `.xcarchive` | iOS release archive | Apple signing | permanent release artifact |
| Exported IPA | iOS distribution where applicable | Apple signing | release artifact |
| Keystore/private key | signing only | secret | never publish |

A useful directory convention is:

```text
mobile/dist/
├── android/
│   ├── damagebdd-release.aab
│   ├── ecai-release.aab
│   ├── damagebdd-upload-cert.pem
│   └── ecai-upload-cert.pem
└── ios/
    ├── DamageBDD.xcarchive
    └── ECAI.xcarchive
```

`dist/` should normally be ignored by Git and populated by local release builds or dedicated release automation.

---

## 17. Suggested release workflow

For normal commits:

```bash
git push
```

GitHub Actions builds the Android debug APKs automatically when `mobile/android/**` changes.

For a candidate release:

```bash
cd mobile

make android-build
# run/test both apps

# produce and sign the release AABs
# verify signatures

git tag -a v0.1.0 -m "Mobile v0.1.0"
git push origin v0.1.0
```

Then:

1. Upload the signed AABs to Play Internal Testing.
2. Test the Play-installed apps.
3. Promote the release when ready.
4. Optionally archive the signed AABs in a GitHub Release.
5. Never publish or commit private signing material.
