# Signing NEFORUM's downloads

NEFORUM is signed only through free routes: no Apple Developer Program and no Google Play account. Every signing step in `.github/workflows/build.yml` runs only when its secrets exist, so the workflow keeps working (unsigned, as before) until the owner sets them up. No key, certificate or account ID is kept in the repository.

| Download | How it is signed | Needs |
|---|---|---|
| Every release file | GitHub artifact attestation (build provenance) | Nothing: works now |
| Windows: `NEFORUM.exe`, the installer, the zip's `NEFORUM.exe` | Authenticode through SignPath Foundation | A SignPath Foundation project |
| Android APKs | NEFORUM's own release key | A keystore in GitHub secrets |
| Firefox extension | Signed by Mozilla (AMO, unlisted channel) | AMO API credentials |
| Chrome extension | Signed by the Chrome Web Store when published there | A Chrome Web Store listing ([chrome-web-store.md](chrome-web-store.md)) |
| Linux tarball and AppImage | Attestation and SHA256SUMS; Flathub signs its own repository | Nothing |
| macOS and iOS | Ad-hoc only (no Apple account) | Not covered |

## Repository secrets and variables

Set them in GitHub: **Settings > Secrets and variables > Actions**. Secrets are hidden; variables are plain settings.

| Name | Kind | Used by |
|---|---|---|
| `SIGNPATH_API_TOKEN` | secret | Windows signing |
| `SIGNPATH_ORGANIZATION_ID` | variable | Windows signing (setting it turns the `windows-signing` job on) |
| `SIGNPATH_PROJECT_SLUG` | variable | Windows signing |
| `SIGNPATH_SIGNING_POLICY_SLUG` | variable | Windows signing (`release-signing`) |
| `SIGNPATH_APP_ARTIFACT_CONFIGURATION` | variable, optional | Windows signing (default `app`) |
| `SIGNPATH_INSTALLER_ARTIFACT_CONFIGURATION` | variable, optional | Windows signing (default `installer`) |
| `ANDROID_KEYSTORE_BASE64` | secret | Android |
| `ANDROID_KEYSTORE_PASSWORD` | secret | Android |
| `ANDROID_KEY_ALIAS` | secret | Android |
| `ANDROID_KEY_PASSWORD` | secret | Android |
| `AMO_JWT_ISSUER` | secret | Firefox extension |
| `AMO_JWT_SECRET` | secret | Firefox extension |

## Build provenance attestations (active)

The release job attests every file it publishes (`actions/attest-build-provenance`, with `id-token: write` and `attestations: write`): GitHub signs a statement, kept in the repository's attestations and in the public Sigstore transparency log, that the file was built by this workflow from this commit. It costs nothing for a public repository and needs no setup.

Anyone can check a download:

```bash
gh attestation verify NEFORUM-Setup-1.3.0.exe --repo Neforuss/NEFORUM
```

The release also carries `SHA256SUMS` (every download) and `latest.json` (the update check's file, which repeats each download's SHA-256).

## Windows: SignPath Foundation

SignPath Foundation gives open-source projects a free code signing certificate in the Foundation's name, kept in SignPath's hardware security module. The project never holds the private key: CI sends the unsigned files to SignPath and gets them back signed. Windows SmartScreen then shows "SignPath Foundation" as the publisher, and its warning fades as the signed downloads gain reputation.

### What CI does

The `windows-signing` job runs for `v*` tags once the variable `SIGNPATH_ORGANIZATION_ID` exists (and fails clearly if the secret `SIGNPATH_API_TOKEN` is missing). It:

1. Takes the `windows` job's `neforum-windows.zip`, unpacks it and uploads the app folder as an artifact.
2. Submits that artifact to SignPath (artifact configuration `app`), waits for it (up to an hour, for an approver to approve) and checks that `NEFORUM.exe` has a valid signature.
3. Builds the Inno Setup installer again (`apps/neforum_app/installer/neforum.iss`) around the signed app, and zips the signed app as `neforum-windows.zip`.
4. Submits the installer (artifact configuration `installer`) and checks its signature.
5. Uploads `neforum-windows-signed`; the release job puts these two files in place of the unsigned ones.

Not signed: the DLLs next to `NEFORUM.exe` (the Flutter engine and plugins are other projects' code, which the Foundation does not sign for us), and the uninstaller `unins000.exe` (Inno Setup signs it only while compiling, through a local `SignTool`, which a remote signing service cannot be).

### Steps for the owner

1. Read the conditions at <https://signpath.org/terms> and apply at <https://signpath.org/> (free for OSI-licensed projects; NEFORUM is GPL-3.0). The application asks for the repository, the maintainers and how releases are built (GitHub-hosted runners, this workflow).
2. Add the code signing policy the Foundation requires to the README (or the website): "Free code signing provided by SignPath.io, certificate by SignPath Foundation", who may commit, review and approve releases, and that NEFORUM sends no data except what the user publishes and the optional update check.
3. When the project is approved, in SignPath:
   - Note the **organization ID** (in the organization's settings).
   - Create the **project**; its **slug** is for example `NEFORUM`.
   - Link the GitHub repository as a **trusted build system** (GitHub.com), so SignPath accepts artifacts from this workflow: <https://docs.signpath.io/trusted-build-systems/github>.
   - Add two **artifact configurations** with these slugs and contents (GitHub delivers each artifact as a zip file):

     `app`:

     ```xml
     <?xml version="1.0" encoding="utf-8"?>
     <artifact-configuration xmlns="http://signpath.io/artifact-configuration/v1">
       <zip-file>
         <pe-file path="NEFORUM.exe">
           <authenticode-sign />
         </pe-file>
       </zip-file>
     </artifact-configuration>
     ```

     `installer`:

     ```xml
     <?xml version="1.0" encoding="utf-8"?>
     <artifact-configuration xmlns="http://signpath.io/artifact-configuration/v1">
       <zip-file>
         <pe-file-set>
           <include path="NEFORUM-Setup-*.exe" />
           <for-each>
             <authenticode-sign />
           </for-each>
         </pe-file-set>
       </zip-file>
     </artifact-configuration>
     ```

   - Use the Foundation's **release-signing** policy (its slug goes in `SIGNPATH_SIGNING_POLICY_SLUG`). It asks an approver to approve each request; the job waits up to an hour.
   - Create a **CI user**, give it submitter rights on the project, and create its **API token**.
4. In GitHub, add the secret `SIGNPATH_API_TOKEN` and the variables `SIGNPATH_ORGANIZATION_ID`, `SIGNPATH_PROJECT_SLUG` and `SIGNPATH_SIGNING_POLICY_SLUG` (plus the two artifact configuration variables if you chose other slugs).
5. Push a tag. The `windows-signing` job runs after `windows`; approve the two requests in SignPath when it asks.

## Android: NEFORUM's own release key

`apps/neforum_app/android/app/build.gradle.kts` signs release builds with the key described in `android/key.properties` when that file exists, and with Flutter's debug key otherwise. With the four Android secrets present, the `android` job writes `android/key.properties` and `android/app/neforum-release.jks` (both ignored by git) before building, so every APK is signed with the release key.

### Steps for the owner

1. Create the key on your own computer (keep the passwords in a password manager):

   ```bash
   keytool -genkeypair -v -keystore neforum-release.jks -alias neforum -keyalg RSA -keysize 4096 -validity 10000
   ```

2. Encode it for GitHub: `base64 -w0 neforum-release.jks` (Linux), `base64 -i neforum-release.jks` (macOS), or `[Convert]::ToBase64String([IO.File]::ReadAllBytes("neforum-release.jks"))` (PowerShell).
3. Add the secrets `ANDROID_KEYSTORE_BASE64` (that text), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (`neforum`) and `ANDROID_KEY_PASSWORD`.
4. **Back the keystore up** (the `.jks` file and both passwords) in at least two places outside GitHub. Secrets cannot be read back from GitHub, and without the key no later version can ever update an installed NEFORUM: everyone would have to uninstall again.

### Switching from the debug key: one uninstall

APKs released so far are signed with the debug key of whichever CI machine built them. Android installs an update only when it is signed with the same key as the installed app, so the first release with the release key cannot update them: Android says the app is not installed or that the package conflicts. Each user uninstalls NEFORUM once and installs the new APK. Uninstalling deletes NEFORUM's data on the phone, so the release notes must say first: use **Settings > Sync** or **Move to another device** to keep accounts, keys and posts. Every later release updates normally.

### F-Droid (outline, not submitted)

F-Droid builds apps from source on its own servers. A merge request to <https://gitlab.com/fdroid/fdroiddata> adds `metadata/org.neforum.app.yml`, roughly:

```yaml
Categories:
  - Internet
License: GPL-3.0-only
SourceCode: https://github.com/Neforuss/NEFORUM
IssueTracker: https://github.com/Neforuss/NEFORUM/issues
Changelog: https://github.com/Neforuss/NEFORUM/releases
AutoName: NEFORUM
RepoType: git
Repo: https://github.com/Neforuss/NEFORUM.git
Builds:
  - versionName: 1.3.0
    versionCode: <pubspec build number>
    commit: v1.3.0
    subdir: apps/neforum_app/android/app
    output: ../../build/app/outputs/flutter-apk/app-release.apk
    srclibs:
      - flutter@<Flutter release tag>
    build:
      - $$flutter$$/bin/flutter config --no-analytics
      - cd ../.. && $$flutter$$/bin/flutter build apk --release --dart-define=NEFORUM_MOBILE=true --dart-define=NEFORUM_STORE_BUILD=true
AutoUpdateMode: Version
UpdateCheckMode: Tags ^v[0-9.]+$
AntiFeatures:
  NonFreeNet:
    en-US: Posts to networks whose servers are not free software (X, Instagram, TikTok and others).
```

Points to settle before submitting:

- `NEFORUM_STORE_BUILD=true` turns NEFORUM's own update check off, since F-Droid brings updates.
- F-Droid's scanner rejects prebuilt binaries and non-free libraries in the build; check its report for the Flutter engine's Play Core references and every plugin's Android dependencies.
- F-Droid signs with its own key unless the build is reproducible and the metadata names NEFORUM's signing certificate (`AllowedAPKSigningKeys`); then users can move between GitHub's APKs and F-Droid's without uninstalling.
- Fastlane-style store text and screenshots can live in the repository (`fastlane/metadata/android/en-US/`).

## Firefox extension: signed by Mozilla (unlisted)

Firefox installs only extensions signed by Mozilla. On the **unlisted** channel Mozilla signs an extension for self-distribution after an automated review, without publishing it on addons.mozilla.org. The `browser-extension` job:

- runs the extension's tests and `web-ext lint` (Mozilla's add-on linter, the same checks AMO runs on upload) on the Firefox build;
- with `AMO_JWT_ISSUER` and `AMO_JWT_SECRET`, signs it with `web-ext sign --channel unlisted` and ships `neforum-extension-firefox-<version>.xpi` instead of the unsigned zip;
- signs each extension version once: AMO refuses a version number twice, so a version an earlier release already shipped signed is taken from that release, after checking that its files are exactly this build's. A changed extension therefore needs a new version number in both manifests.

Without the secrets the unsigned `neforum-extension-firefox-<version>.zip` ships, as before.

### Steps for the owner

1. Sign in at <https://addons.mozilla.org/developers/> with a Mozilla account (free).
2. Open **Tools > Manage API Keys** (<https://addons.mozilla.org/developers/addon/api/key/>) and generate credentials.
3. Add the **JWT issuer** as the secret `AMO_JWT_ISSUER` and the **JWT secret** as `AMO_JWT_SECRET`.
4. The add-on id `neforum-extension@neforus.com` is in `extensions/browser/manifest.firefox.json`; the first signing request registers it to your account.

A public listing on addons.mozilla.org (found by search, updated by Firefox) is a separate submission: [firefox-amo.md](firefox-amo.md).

## Chrome extension

Chrome signs extensions itself when they are installed from the Chrome Web Store; outside the store, Chrome only loads them unpacked in developer mode. Publishing needs a Chrome Web Store developer account (one-time US$5) and is done by hand: [chrome-web-store.md](chrome-web-store.md).

## Linux

The tarball and the AppImage are not signed with a key of their own: they carry the build provenance attestation and their SHA-256 in `SHA256SUMS`. AppImage's optional GPG signature (`appimagetool --sign`) would need a GPG key in CI secrets; it is not set up. Flathub signs its repository itself ([packaging/flatpak](../packaging/flatpak/org.neforum.NEFORUM.yml)); NEFORUM turns its own update check off inside a Flatpak.

## macOS and iOS

Apple signing needs the paid Apple Developer Program, which is out of scope. The Mac builds stay ad-hoc signed (the first launch needs right-click > Open), and the iOS build stays an unsigned IPA for sideloading.
