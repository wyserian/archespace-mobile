# ArcheSpace

[![Release APK](https://github.com/wyserian/archespace-mobile/actions/workflows/release.yml/badge.svg)](https://github.com/wyserian/archespace-mobile/actions/workflows/release.yml)
[![Version](https://img.shields.io/github/v/release/wyserian/archespace-mobile)](https://github.com/wyserian/archespace-mobile/releases)
[![License](https://img.shields.io/github/license/wyserian/archespace-mobile)](LICENSE)

ArcheSpace is an open-source, encrypted space for capturing and organising your information, notes, projects, secrets, code, checklists and ideas. Group them into spaces, and fill each space with the content type that fits: plain notes, rich text documents, lists and checklists, tables, Kanban boards, code snippets and whiteboards. Anything sensitive can be protected so it only opens with your vault PIN. Everything is taggable, searchable and kept in one place, synced across your devices.

Privacy is built in, not bolted on. It follows a zero-knowledge architecture: your content is encrypted on-device and the backend only ever stores ciphertext, so the server, its operators, and the developers never see your data in readable form.

This is the Android and iOS app, built with Flutter. It talks to the **same Supabase backend** as the [web app](https://github.com/wyserian/archespace) and shares the same client-side `arc1` encryption format, so a vault created on one client opens on the other.

## Table of contents

- [Features](#features)
- [Item types](#item-types)
- [Security model](#security-model)
- [Setup](#setup)
- [Building a release](#building-a-release)
- [Release verification](#release-verification)
- [Tech stack](#tech-stack)
- [Project structure](#project-structure)
- [Roadmap](#roadmap)
- [Help and support](#help-and-support)
- [Contributing and development](#contributing-and-development)
- [Credits](#credits)
- [License](#license)

## Features

- **Zero-knowledge encryption**: the server only ever stores ciphertext ([Security model](#security-model))
- **Vault PIN** with a recovery code, auto-lock and fingerprint / face unlock
- **Protected** items and spaces, and **read-only** spaces
- **Spaces** with sub-spaces, tags and colours
- **Item types**: notes, rich text, lists, checklists, cards, tables, Kanban boards, whiteboards and code ([Item types](#item-types))
- **Reminders** as notifications that repeat or stay until turned off, all listed on one screen
- **Search** across spaces, tags and content
- **Starred**, **archive** and **recycle bin**
- **Realtime sync** with the [web app](https://github.com/wyserian/archespace), and **offline mode**
- **Encrypted backups** and **PDF export**
- **Local mode**: no account, nothing leaves the phone
- **Two-factor sign-in**
- **Verifiable build** linked to its source commit ([Release verification](#release-verification))

## Item types

| Type | Description |
|------|-------------|
| Note | Free-form plain text. |
| Rich text | A full document editor, the same one as the web app (bundled offline): headings, bullet, numbered and task lists, quotes, code blocks, tables, links, highlight, text alignment, superscript and subscript, line spacing, and find and replace (with regular expressions), from a native toolbar. Cards show a native preview. |
| List | Bullet or numbered list (a Numbered checkbox switches between them); numbering updates as rows are added, removed, or reordered. |
| Checklist | Items with checkboxes and progress tracking. |
| Cards | Title and description pairs for planning and grouping ideas. |
| Table | Rows and columns of text with a header row. Copies as tab-separated values that paste straight into a spreadsheet. |
| Kanban | Cards in columns (To do, Doing, Done to start) that scroll sideways: drag a card by its handle, or use its menu's Move to; rename, move and delete columns. Cards show a preview of the columns. |
| Whiteboard | An Excalidraw board: shapes, arrows, text and freehand drawing on a canvas you can pan and zoom. |
| Code | A code snippet in a monospace block with automatic syntax highlighting (language auto-detected). Copies as plain text. |

Older item types are converted automatically: Markdown notes open as Rich text (and are saved that way on the next edit), and Secrets become Notes after unlock (protect them to keep them behind your PIN).

## Security model

Two separate secrets: a **login password** for the account and a **vault PIN** (or passphrase) for the content.

- **Encrypted on the device.** Content is encrypted with AES-256-GCM before it leaves the phone; the server stores only ciphertext and non-sensitive metadata (IDs, timestamps, positions, flags). The offline cache and write queue hold ciphertext too.
- **PIN never stored.** A random vault key is wrapped with a key derived from the PIN by Argon2id.
- **Same format as the web app** (`arc1`), checked against shared test vectors in [`spec/`](spec/).
- **Unlock.** The unlocked key lives only in memory and the vault auto-locks when idle. Fingerprint / face unlock keeps the wrapped key in the Android Keystore / iOS Keychain.
- **Server-side guards.** Row Level Security limits each user to their own data, repeated wrong PINs lock the vault, and optional two-factor sign-in is enforced by the database, not just the app.
- **Protected items and spaces** need the PIN again inside an unlocked vault: a guard against someone using your unlocked phone.
- **Encrypted backups** open in the same vault, or anywhere with the PIN used when exporting.
- **No backdoor.** A one-time recovery code resets a forgotten PIN. Lose both and the data can't be recovered.

**Limits.** A short PIN can be guessed offline if a backup file leaks, so prefer a longer one. Client-side encryption is only as safe as the code running it; Settings links the build to its source commit ([Release verification](#release-verification)).
## Setup

### 1. Prerequisites

- The [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel; this project builds with Flutter 3.44.x / Dart 3.12+).
- Android Studio / Xcode toolchains for the platforms you target.
- A running Supabase project - the **same one** the web app uses. Follow the web [README](https://github.com/wyserian/archespace#setup) to create and configure it.

### 2. Clone and install

```bash
git clone https://github.com/wyserian/archespace-mobile
cd archespace-mobile
flutter pub get
```

### 3. Configure Supabase credentials

The app reads its config from `--dart-define` values at build time (never committed). Copy the example and fill in the same values the web app uses:

```bash
cp env.example.json env.json
```

```json
{
  "SUPABASE_URL": "https://your-project-id.supabase.co",
  "SUPABASE_ANON_KEY": "your-anon-key"
}
```

`env.json` is gitignored.

### 4. Add mobile redirect URLs in Supabase

Because this app shares the backend, add its auth redirect URLs alongside the web ones in **Supabase > Authentication > URL Configuration**. Password reset links open the web app's reset page (the Supabase Site URL); after resetting, sign in again on mobile.

### 5. Choose single-user or multi-user

Sign-up (the "Create account" option) is shown by default. To hide it for a single-user install, build with:

```bash
--dart-define=ALLOW_SIGNUP=false
```

Sign-up must also be enabled in Supabase Auth for account creation to succeed.

### 6. Run

```bash
flutter run --dart-define-from-file=env.json
```

## Building a release

`flutter run` leaves the build hash as `dev`. To produce a release APK stamped with the source commit, use the helper script (reads `env.json` and the current git commit):

```bash
./scripts/build-apk.ps1
```

Or invoke Flutter directly:

```bash
flutter build apk --release --dart-define-from-file=env.json --dart-define=BUILD_HASH=$(git rev-parse --short HEAD)
```

Commit your changes first so the stamped hash exists on GitHub. A local release build is signed with the key in `android/key.properties` (git-ignored) when it exists, and with the debug key otherwise:

```properties
storeFile=C:/path/to/archespace-release.jks
storePassword=...
keyAlias=archespace
keyPassword=...
```

### Release key

Every release must be signed with the same key, or Android refuses to install it as an update. Create it once, keep it backed up somewhere safe, and never commit it:

```bash
keytool -genkeypair -v -keystore archespace-release.jks -alias archespace -keyalg RSA -keysize 4096 -validity 10000
```

## Release verification

Pushing a `vX.Y.Z` tag runs the **Release APK** workflow ([`.github/workflows/release.yml`](.github/workflows/release.yml)), which builds on CI, stamps the exact commit, and publishes to a GitHub Release with SHA-256 checksums: a universal APK and a smaller arm64 one for nearly every phone. The version comes from the tag. The app version shown in Settings links to that commit, so anyone can confirm the installed binary was built from the audited, open-source code. The release notes list the signing certificate's SHA-256, and the workflow refuses to publish if any secret below is missing.

The workflow needs these repository secrets, set under **Settings > Secrets and variables > Actions**:

- `SUPABASE_URL`, `SUPABASE_ANON_KEY` - the same values as `env.json`
- `ANDROID_KEYSTORE_BASE64` - the release key file, base64-encoded (`base64 -w0 archespace-release.jks`)
- `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`

Cut a release by tagging and pushing:

```bash
git tag v0.1.0
git push origin v0.1.0
```

You can also run the workflow manually from the Actions tab.

## Tech stack

| Layer | Technology |
|-------|------------|
| Framework | Flutter (Material 3), Dart |
| Backend | Supabase Auth, PostgreSQL, Row Level Security, Realtime (`supabase_flutter`) |
| Encryption | AES-256-GCM with Argon2id key derivation (`cryptography`) |
| Secure storage | `flutter_secure_storage` (Android Keystore / iOS Keychain) |
| Biometrics | `local_auth` |
| Rich text | The web app's Tiptap editor, bundled offline into `assets/rich_text_editor.html` and run in `webview_flutter`, with a native toolbar and preview |
| Whiteboard | The web app's Excalidraw board, bundled offline (fonts included) into `assets/whiteboard_editor.html` and run in `webview_flutter`; cards and PDFs show the preview image saved with each board |
| Markdown | `flutter_markdown` (older Markdown notes) |
| Syntax highlighting | `flutter_highlight` + `highlight` (automatic language detection for the Code item type) |
| PDF export | `pdf` + `printing` (native share/print sheet) |
| Files | `file_picker` (JSON backup), `path_provider` (offline cache) |
| Preferences | `shared_preferences` (theme, accent, sort, and item view) |
| Links | `url_launcher` (build-commit link) |
| CI | GitHub Actions (stamped release APK) |

## Project structure

```text
archespace-mobile/
  .github/
    workflows/            # release.yml - stamped release APK
  android/
  ios/
  lib/
    main.dart             # bootstrap: Supabase init, appearance, write-queue replay
    src/
      app.dart            # root gate: login -> 2FA -> vault setup/unlock -> spaces
      features/
        auth/             # sign in, sign up, password policy, two-factor auth (TOTP)
        vault/            # crypto vault, PIN/recovery, biometric unlock, setup/unlock, protected content
        spaces/           # spaces list, editor, cards, read-only and protect
        items/            # item types, editors (incl. the Rich text and Whiteboard WebViews), cards, clipboard
        starred/          # starred spaces and items
        reminders/        # the Reminders screen and local notifications
        search/           # unified search + jump-to-item
        storage/          # archive + recycle bin
        settings/         # account, security, appearance, backup, build footer
        backup/           # JSON import/export
      shared/
        config/           # app config + build info
        crypto/           # arc1 port (AES-GCM, Argon2id)
        data/             # encrypted offline read cache
        offline/          # durable write queue
        realtime/         # postgres-changes watcher
        export/           # PDF exporter
        sort/             # sorting helpers
        util/, widgets/
  assets/
    rich_text_editor.html # offline Rich text editor, built from the web repo (npm run build:mobile-editor)
    whiteboard_editor.html # offline Whiteboard (Excalidraw), built by the same command
  scripts/
    build-apk.ps1         # local stamped release build
  spec/                   # crypto contract + conformance vectors, welcome space content
  test/
  pubspec.yaml
  env.example.json
```

Each feature follows a `data` / `domain` / `application` / `presentation` layering. Data access sits behind repositories so a future first-party backend can swap in.

## Roadmap

- **Push notifications**: "something changed" signals only (never content), sent server-side.
- **iOS signing**: so iOS releases are store-ready.
- **First-party backend**: mirrors the web roadmap - a self-contained backend the project owns, landing incrementally behind configuration. The zero-knowledge design does not change.

Other improvements are tracked as issues. If there is something you want to see, propose it there.

## Help and support

Need help with setup, self-hosting, login, password recovery, or vault PIN recovery? Reach out at **[support@archespace.app](mailto:support@archespace.app)**, or open an issue on the repository.

Before reaching out, it helps to include what you were trying to do and what happened, your deployment type (single- or multi-user), your device and OS version, and any relevant logs with secrets redacted.

## Contributing and development

Contributions are welcome, including bug fixes, features, and docs.

- Fork the repository, create a feature branch, and open a pull request against `main`.
- Keep PRs focused and include a short description of the change and why it is needed.
- Run `flutter analyze` and `flutter test` before submitting.
- The crypto port is safety-critical: if you touch `lib/src/shared/crypto/`, keep it byte-compatible with the web `arc1` format and re-run the conformance vectors.
- For larger or security-relevant changes, open an issue first so the approach can be discussed.

For development questions, contact **[support@archespace.app](mailto:support@archespace.app)**.

## Credits

- Built with Flutter and Dart (Material 3).
- Backend, authentication, and realtime sync powered by Supabase.
- Encryption via the `cryptography` package (AES-256-GCM, Argon2id); the `arc1` format is shared with the web app.
- Rich text editing with Tiptap and the Whiteboard with Excalidraw (both shared with the web app) in `webview_flutter`; item rendering with `flutter_markdown` and `flutter_highlight` + `highlight`; PDF export via `pdf` + `printing`.
- Source hosted on GitHub.
- Crafted and maintained by Wyserian.

## License

ArcheSpace is released under the MIT License. See [LICENSE](LICENSE).
