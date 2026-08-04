# Changelog

## 1.0.9 — Stable background restoration

- Recheck and, when KakaoTalk reacquires the foreground while an exact room
  finishes opening, re-restore the same verified prior application before any
  message bytes can enter a composer.
- Use the normal bounded AppKit activation request that a CLI can issue; the
  cooperative source-app API requires the foreground app to yield first and
  was rejected without opening a room.
- Bind the sender to the foreground process recorded by room preparation so a
  delayed focus change fails before composition.
- Track unrelated background rooms by their stable window, title, and composer
  identities without requiring macOS to expose a transient empty `AXValue`.
- Preserve strict empty/clean composer checks for the target and for every room
  before the only permitted temporary-activation path.

## 1.0.8 — Dynamic chat-preview compatibility

- Restore background exact-row verification for current KakaoTalk chat lists
  whose preview containers hold zero, one, or multiple dynamic payload nodes.
- Continue requiring exactly one direct Chats table, navigation proof, name,
  profile control, metadata label, preview container, and destination row.
- Update the fail-closed empty-composer fingerprint for KakaoTalk's current
  `_NS:54` control and anonymous image/text leaves.
- Treat a missing optional `AXHidden` attribute as unknown-but-not-hidden while
  retaining exact role, label, frame, action, and enabled-state Send checks.
- Wait up to two seconds for KakaoTalk to enable the exact Send control after
  accepting the message, while continuously requiring unchanged foreground.

## 1.0.7 — Existing sender hardening

- Keep the v1.0.6 exact-ID warm-up and control-only sender architecture.
- Require the exact Send control to explicitly report `AXHidden == false`;
  missing visibility evidence now fails before message composition.
- Reject hard-linked send/service lock files before changing permissions or
  acquiring them, and re-verify user ownership, type, link count, and mode.

## 1.0.6 — Exact-ID room warm-up

- Add automatic, no-message room warm-up before sends and an explicit
  `kakaocli warmup --chat-id/--self` command.
- Isolate temporary KakaoTalk activation and the exact row-bound native
  enter-chatroom context-menu action in a single guarded source file; verify
  the exact newly opened room and restore the prior application before
  composing. No keyboard event is created or posted.
- Keep the normal sender control-only and allow unrelated structurally verified
  room windows to remain open and untouched.
- Add warm-up receipts, local-service protocol v2 routing, no-reservation
  ordering tests, restricted-source/symbol release guards, and CLI help checks.

## 1.0.5 — Strict background control-only sending

- Remove all Accessibility focus/row-selection mutation and all keyboard event
  construction/posting from the send transport after a failed focus attempt
  showed that inactive KakaoTalk could become active.
- Require one already-open exact target room and one stable AXPress-capable
  Send/전송 control; fail before composition when the room or control is absent.
- Recheck the frontmost application after composition, immediately before the
  exact Send control, and after invocation so focus changes fail closed or
  become an `unknown` post-action outcome.

## 1.0.4 — Current KakaoTalk background verifier

- Recognize KakaoTalk's current stateless direct navigation buttons only when
  jointly proven with exactly one current chat-row schema.
- Update exact row-name resolution to the current Accessibility identifier and
  retain fail-closed rejection for missing, duplicate, generic, or stale UI
  structures.
- Discover only direct rendered window children when inactive KakaoTalk
  temporarily exposes an empty `AXWindows` collection.
- Safely reuse one exact target-title room only when no other room is open, the
  database/UI destination remains unique, and its sole composer is empty.
- Expand source guards against app activation, window ordering, cursor APIs,
  global event posting, and application launch helpers.

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
