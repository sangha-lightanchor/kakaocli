# Changelog

## 1.0.3 — Conservative post-action failures

- Convert unclassified UI transport errors and database/receipt confirmation
  failures after a reserved send action into durable `unknown` receipts. These
  paths never expose an error that a caller could mistake as safe to retry.

## 1.0.2 — Prompt-free state key and verified recovery

- Replaced the final runtime Keychain dependency with atomic, fail-closed
  mode-0600 file storage for the separate local state-database key.
- Added read-only source-database proof for restoring a previously confirmed
  request receipt without invoking the UI or weakening duplicate protection.
- Removed the obsolete LocalAuthentication and Security framework links and
  made the same-process lock test deterministic under loaded CI runners.

## 1.0.1 — Noninteractive database and runtime hardening

- Removed the source SQLCipher key from Keychain, command arguments, and local
  caches; normal reads derive it in memory from a mode-0600 path/user-ID cache.
- Made encrypted state-key reads noninteractive and fail closed without
  replacing an inaccessible key.
- Rejected all already-open room windows, revalidated UI identity immediately
  before action, and strengthened same-process and cross-process send locking.
- Added durable late reconciliation for `unknown` receipts without a second UI
  action, with exclusive confirmed-log claims across request IDs.
- Hardened the optional service with a lifetime lock, same-user peer checks,
  bounded framed I/O, deadlines, safe socket cleanup, and watcher rearming.
- Added checkpointed archive catch-up, background leased media/outbox work,
  approved-host streaming downloads, content-object verification, path-free
  webhook DTOs, and redirect rejection.
- Pinned dependencies, added CI/release guards, and made nonportable Homebrew
  SQLCipher binary artifacts fail closed while retaining supported source
  builds.

## 1.0.0 — Safe local rebuild

- Added the concurrency-safe `KakaoClient` actor and stable send types.
- Restricted sends to exact chat IDs or self-chat, with stdin bodies and
  caller-supplied request IDs.
- Added whole-transaction process locking, fail-closed UI proof, exact database
  confirmation, and durable `confirmed`/`unknown` receipts.
- Resolve the self-chat window title from the logged-in user's database record
  while continuing to prove the UI row by KakaoTalk's unique self-chat badge.
- Reserve request IDs durably before UI submission so a process crash cannot
  turn an uncertain first attempt into a duplicate retry.
- Removed app lifecycle automation, name/substring sending, harvest UI actions,
  and all foreground/global input paths.
- Added the optional user-only Unix-socket service, vnode database/WAL events,
  encrypted allowlisted archive, verified content-addressed media, generic
  durable webhook, and idempotent local migration.

### v0.5.0 - Chat Harvest (Phase 4)
- `harvest` command: bulk-capture chat display names and load message history
- Vision framework OCR to locate "View Previous Chats" button
- CGEvent-based clicking for reliable UI interaction
- CGWindow API for paywall popup detection
- Auto-dismiss Talk Drive Plus paywall dialogs
- MetadataStore: persistent chatId → displayName at `~/.kakaocli/metadata.json`
- `query` command: raw read-only SQL queries against the decrypted database

### v0.4.1 - Robust Auto-Login
- Fix credential storage: switch from Security framework to `security` CLI
- Fix state detection: use status bar menu when AX window is not visible
- Fix login transition: non-aggressive polling avoids interfering with login flow

### v0.4.0 - App Lifecycle & Login (Phase 3.5)
- `login` command: store/check/clear credentials (macOS Keychain)
- AppLifecycle: auto-launch KakaoTalk, auto-login via AX automation
- `ensureReady()` called before all send operations

### v0.3.0 - Agent Integration (Phase 3)
- `sync` command with `--follow` for real-time NDJSON message streaming
- Webhook support: `--webhook <url>` POSTs new message batches
- AGENTS.md: AI agent integration instructions

### v0.2.0 - UI Automation (Phase 2)
- Send messages via macOS Accessibility API
- `send` command with chat name matching
- `--me` flag for self-chat (나와의 채팅) via badge detection
- `inspect` command to dump UI element tree

### v0.1.0 - Database Reader (Phase 1)
- SQLCipher database decryption (PBKDF2-SHA256, cipher_default_compatibility=3)
- Auto-detect device UUID, user ID, container path
- `auth`, `chats`, `messages`, `search`, `schema`, `status` commands
- JSON output for all read commands
