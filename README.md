# ArcheSpace

[![Release APK](https://github.com/bitwyser/archespace-mobile/actions/workflows/release.yml/badge.svg)](https://github.com/bitwyser/archespace-mobile/actions/workflows/release.yml)
[![Version](https://img.shields.io/github/v/release/bitwyser/archespace-mobile)](https://github.com/bitwyser/archespace-mobile/releases)
[![License](https://img.shields.io/github/license/bitwyser/archespace-mobile)](LICENSE)

ArcheSpace is an open-source, encrypted space for capturing and organising your information, notes, projects, secrets, code, checklists and ideas. Group them into spaces, and fill each space with the content type that fits: plain notes, rich text documents, lists and checklists, tables, code snippets and whiteboards. Anything sensitive can be protected so it only opens with your vault PIN. Everything is taggable, searchable and kept in one place, synced across your devices.

Privacy is built in, not bolted on. It follows a zero-knowledge architecture: your content is encrypted on-device and the backend only ever stores ciphertext, so the server, its operators, and the developers never see your data in readable form.

This is the Android and iOS app, built with Flutter. It talks to the **same Supabase backend** as the [web app](https://github.com/bitwyser/archespace) and shares the same client-side `arc1` encryption format, so a vault created on one client opens on the other.

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

- **Local mode** ("Use without an account" on the sign-in screen): no account and no server. Everything is kept in the app's private storage, still encrypted with the vault PIN, and nothing is sent anywhere. The data classes talk to a local store (`lib/src/shared/data/local_db.dart`) that follows the same database rules. Move to an account later with an encrypted backup.
- **Welcome space** for new accounts: a short tour of spaces, item types and the vault, created and encrypted on the device right after the vault is set up (content shared with the web app in `spec/welcome-space.json`).
- **Spaces** for separating projects and ideas, with one level of nesting (sub-spaces), tags, a space colour, pinning, and drag-and-drop reordering.
- **Many item types** for different kinds of content, from notes and checklists to rich text documents, tables, whiteboards and code (see [Item types](#item-types)).
- **Protect** any item or space so its content only opens with your vault PIN (or fingerprint / face when biometric unlock is on); its name stays visible (see [Security model](#security-model)).
- **Read-only spaces**: lock a space against edits (enforced by the database) while still viewing, copying, and exporting it.
- **Starred** view for quick access to the spaces and items you use most, wherever they live.
- **One + button** that opens New item and New space.
- **Grid or list views**, per-view sort (default / name / newest), and search: a unified search across spaces, tags, and item content with jump-to-item, plus a compact in-space search that filters a space's items by title or tag.
- **Navigation drawer** for Spaces, Starred, Archive, and Recycle bin (with live counts), plus quick Lock, Sign out, and Settings.
- **Auto-save**, one-tap copy, bulk actions, and duplicate / move / archive / restore / delete workflows.
- **Undo** for archive and move-to-bin, right from the confirmation snackbar.
- **Archive** and a **recycle bin** (restore or permanently delete).
- **PDF export** of a whole space or a single item via the native share/print sheet, with a branded header, footer URL, and page numbers.
- **Encrypted backups** in the same format as the web app: a backup file only opens with your vault, and imports on any account.
- **Appearance**: System / Dark / Light modes and five accent colours (mint, lavender, amber, sky, rose), synced to your account, plus a one-tap theme shuffle in the drawer.
- **Encrypted vault** with configurable auto-lock and optional biometric unlock (fingerprint or face) (see [Security model](#security-model)).
- **Optional two-factor sign-in** (TOTP) with a one-time backup code.
- **Vault management**: change PIN with the current PIN, reset PIN with a recovery code, and generate a new recovery code.
- **Account management**: create account, change email, change login password, forgot password, and permanent account deletion.
- **Realtime sync** and pull-to-refresh across spaces and items.
- **Offline mode**: read and edit from an encrypted on-device cache; a durable write queue replays edits when you reconnect.
- Single-user by default, with an optional multi-user (sign-up) mode.
- **Verifiable build**: the app version in Settings links to the exact source commit on GitHub.

## Item types

| Type | Description |
|------|-------------|
| Note | Free-form plain text. |
| Rich text | A full document editor, the same one as the web app (bundled offline): headings, bullet, numbered and task lists, quotes, code blocks, tables, links, highlight, text alignment, superscript and subscript, line spacing, and find and replace (with regular expressions), from a native toolbar. Cards show a native preview. |
| List | Bullet or numbered list (a Numbered checkbox switches between them); numbering updates as rows are added, removed, or reordered. |
| Checklist | Items with checkboxes and progress tracking. |
| Cards | Title and description pairs for planning and grouping ideas. |
| Table | Rows and columns of text with a header row. Copies as tab-separated values that paste straight into a spreadsheet. |
| Whiteboard | An Excalidraw board: shapes, arrows, text and freehand drawing on a canvas you can pan and zoom. |
| Code | A code snippet in a monospace block with automatic syntax highlighting (language auto-detected). Copies as plain text. |

Older item types are converted automatically: Markdown notes open as Rich text (and are saved that way on the next edit), and Secrets become Notes after unlock (protect them to keep them behind your PIN).

## Security model

ArcheSpace uses a device-side vault model. You sign in with Supabase Auth using a login password, then unlock a separate vault PIN or passphrase to access encrypted data - the password proves account ownership, the PIN or passphrase protects the content itself.

**Encryption**

- Space and item content (names, descriptions, tags, titles, and content) is encrypted on-device with AES-256-GCM before it reaches Supabase. Only non-sensitive metadata - IDs, timestamps, positions, and flags like pinned/archived/deleted - stays in plain form.
- The vault secret is never stored as plaintext. It can be a numeric PIN or a longer passphrase. On setup, the app generates a random vault master key, which is wrapped with a key derived from your PIN or passphrase using Argon2id, a memory-hard key-derivation function.
- The crypto format (`arc1`) is byte-compatible with the web app and validated against shared conformance vectors (see [`spec/`](spec/)), so data encrypted on either client decrypts on the other.

**Sessions and access**

- The unlocked vault key is held in memory for the running process. Only ciphertext is ever written to disk - the offline read cache and write queue store encrypted rows.
- With biometric unlock enabled, the wrapped master key is stored in the Android Keystore / iOS Keychain and released only after a successful fingerprint or face check.
- The vault can be locked manually from Settings, and is cleared on sign out.
- Signing out ends only this device's session by default; Settings also offers "Sign out of all devices" to revoke every session at once.
- Supabase Row Level Security restricts each user to their own rows.

**Two-factor authentication (2FA)**

- Optional TOTP two-factor authentication can be enabled per account from Settings, under Account. It is off by default for every existing and new account; each user opts in manually.
- Enrolment uses Supabase's native MFA: scan the QR code (or enter the key) into an authenticator app such as Google Authenticator, Authy, or 1Password. The TOTP secret is held only by Supabase Auth and is never stored in a client-readable table, so 2FA still protects the account if the login password is compromised.
- When 2FA is on, sign-in asks for the authenticator code after the password and before the vault unlock, so the order is login password, then 2FA, then vault PIN.
- Row Level Security enforces this at the database as well: once a verified factor exists, the account's data - including the wrapped vault key - is only readable after the second factor is verified (AAL2), so 2FA cannot be bypassed by calling the API directly. Accounts without 2FA are unaffected.
- A one-time backup code is shown once when 2FA is enabled, and can be regenerated from Settings. Only its SHA-256 hash is stored. The backup code can be used at sign-in if the authenticator is lost; using it removes the factor so you can sign in and set 2FA up again. (One code is enough because redeeming it disables 2FA.)
- Disabling 2FA requires re-entering the login password.
- This shares the same Supabase project and `mfa_backup_codes` schema as the web app, so 2FA enabled on one client applies to sign-in on both.

**Protected items and spaces**

- A protected item keeps its title and tags visible, and a protected space its name; the content stays hidden until you enter your vault PIN (or confirm with biometrics when biometric unlock is on), including in search, Starred, PDF export, and copy.
- Opened content hides again when the vault locks. Five wrong PINs in a row lock the whole vault.
- Protection is a PIN check inside an already unlocked vault (the content is encrypted with the same vault key as everything else), so it guards against someone using your unlocked phone, not against someone who can inspect the running app.

**Encrypted backups**

- A backup file holds your spaces and items encrypted with the vault key, plus that key wrapped with your vault PIN (as the server stores it), in the same format as the web app.
- It opens directly in the same vault, and anywhere else (another account, or after a vault reset) with the vault PIN you had when exporting. After a PIN change, older backups still need the earlier PIN.

**Recovery**

- A one-time recovery code is generated during initial vault setup and shown once - it is not emailed, so it must be saved when shown.
- The recovery code can be recreated from Settings by entering the current vault PIN.
- If the PIN is forgotten, the "Reset PIN with recovery code" flow in Settings uses the recovery code to set a new vault PIN.
- Resetting with a recovery code generates a new recovery code and invalidates the previous one.

**Account deletion**

- Deleting an account permanently removes the user and, by cascade, all of their spaces, items, and encrypted vault data.
- Deletion re-verifies both the login password and the vault PIN before proceeding.

**Limits to be aware of**

- The app cannot recover encrypted content without either the current vault PIN or the current recovery code - there's no backdoor.
- If both the vault PIN and recovery code are lost, encrypted space data cannot be decrypted.
- Backups are encrypted, but a short vault PIN can be guessed offline if a backup file leaks; a longer PIN or passphrase makes backups much harder to open. Store them carefully.
- Client-side encryption is only as safe as the code your device runs. Settings shows the exact build commit (linked to GitHub) so you can verify the running code against a tagged release (see [Release verification](#release-verification)).

**Privacy and legal**

- Accepting the Terms of Service and Privacy Policy is required at sign-up, and the accepted version is recorded server-side. Both policies are linked from the sign-up screen and Settings.

## Setup

### 1. Prerequisites

- The [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel; this project builds with Flutter 3.44.x / Dart 3.12+).
- Android Studio / Xcode toolchains for the platforms you target.
- A running Supabase project - the **same one** the web app uses. Follow the web [README](https://github.com/bitwyser/archespace#setup) to create and configure it.

### 2. Clone and install

```bash
git clone https://github.com/bitwyser/archespace-mobile
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

Commit your changes first so the stamped hash exists on GitHub. The release APK is currently signed with the debug key (see `android/app/build.gradle.kts`); add a real keystore before distributing through an app store.

## Release verification

Pushing a `v*` tag runs the **Release APK** workflow ([`.github/workflows/release.yml`](.github/workflows/release.yml)), which builds the APK on CI, stamps it with the exact commit, and publishes it to a GitHub Release with a SHA-256 checksum. The app version shown in Settings links to that commit, so anyone can confirm the installed binary was built from the audited, open-source code.

The workflow needs two repository secrets (the same values as `env.json`), set under **Settings > Secrets and variables > Actions**:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`

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
- **Release signing**: ship a real Android keystore (and iOS signing) so releases are store-ready.
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
- Crafted and maintained by BitWyser.

## License

ArcheSpace is released under the MIT License. See [LICENSE](LICENSE).
