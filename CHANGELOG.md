# Changelog

### Unreleased
- Replaced name and substring sending with exact `chat_id` or self-chat destinations
- Added caller request IDs, durable idempotent receipts, and whole-transaction process locking
- Added fail-closed UI identity checks and exact per-chat database confirmation
- Removed foreground send mode, application activation, window raising, pointer movement, global input, positional Send-button guessing, and automatic room closing from the send path
- Added explicit `confirmed` and `unknown` outcomes; unknown results are never retried automatically
- Resolve self-chat window identity from the logged-in user's database name while proving the row by its unique self badge
- Complete bounded read-only room preflight before receipt reservation, then reserve request IDs before composer mutation so a process crash cannot become a duplicate retry
- Resolve every first-attempt destination freshly, reject database-wide duplicate UI identities, and require structural proof of the selected/current Chats table
- Reuse one certified exact target room while permitting only uniquely titled,
  certified, empty, snapshotted unrelated rooms that remain unchanged and
  unfocused; reject drafts and ambiguous composition state
- Reject closed rooms and foreground KakaoTalk; add `send --preflight` for
  receipt-free live readiness checks
- Support KakaoTalk 26.x direct-window exposure, current chat-row identifiers, and stateless navigation with complete chat-row schema proof
- Pin background submission to the self-chat-certified KakaoTalk 26.6.1 (1190)
  build, set only the exact target room/composer as Kakao's internal
  main window/first responder, and post Return only to KakaoTalk's PID while
  proving the OS foreground app remains unchanged
- Retain one direct visible frame-contained Send control as identity/stability
  evidence without pressing it, support tightly anchored transient composer
  re-instantiation, and re-resolve database identity immediately before Return
- Support both certified current and legacy KakaoTalk 26.x room chrome variants
- Permit self-chat identity through one exact selected badge-marked Friends row
  when the complete Friends/Chats/More navigation and table shape are proven
- Cache only the mode-0600 source database path/user ID, derive SQLCipher keys in memory, and make expensive identity recovery explicit through `auth --refresh`
- Stop `status` from querying the legacy credential Keychain or causing an unrelated permission prompt
- Stop self-chat and composer discovery at certified UI containers instead of recursively scanning message previews/history
- Replace SQL-interpolated database keys with SQLCipher's typed key API and remove key-bearing CLI arguments in favor of bounded `--key-stdin`
- Enforce user-owned regular database files, SQLite query-only mode, and one read-only raw statement with no attach or trailing SQL
- Require HTTPS for remote webhooks, reject URL credentials and downgrade redirects, use an ephemeral cookie-free session, and bound sync intervals
- Persist harvested chat-name metadata atomically in a user-owned mode-0600 file and reject symlinked or corrupt state
- Bound KakaoTalk Accessibility messaging so stalled AX calls fail closed instead of hanging indefinitely
- Restrict send identity scans to at most 64 visible rows, reducing a live closed-room preflight from roughly 40 seconds to under one second
- Resolve blank-name group chats only when secure harvested titles exactly match current source membership IDs, participant names, type, and count
- Harden state and lock files against symlinks, wrong owners, and non-user permissions; give each confirmed chat/log row one durable request owner
- Reconcile stored `unknown` attempts read-only under the same request ID without repeating UI work
- Keep every post-composition failure durably `unknown`, even when best-effort
  cleanup empties the composer, closing a duplicate-retry race
- Limit send bodies to 64 KiB and remove source-database keys from send-process arguments
- Return durable `unknown` for unclassified UI or confirmation failures after
  reservation, and fsync the receipt directory entry before reporting success

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
