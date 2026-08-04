# CLAUDE.md

Follow the complete shared safety contract in `AGENTS.md`.

## Architecture

- `KakaoClient` is the concurrency-safe public actor and owns the persistent
  read-only database connection, send serialization, events, and archive work.
- `SafeSendCoordinator` owns request validation, idempotency, the full send
  lock, no-send warm-up ordering, high-water snapshot, exact-byte confirmation,
  and receipts.
- `ForegroundRoomWarmup` is the only foreground-capable component. It opens one
  exact database-resolved row through its native context menu and one exact
  localized enter-chatroom AXPress, restores the prior app, and has no body,
  focus/selection, keyboard-event, or Send-control capability.
- `SafeKakaoSender` is the only send UI transport. Its pre-action failures prove
  no action occurred; post-control uncertainty becomes `unknown`. It operates
  only on a prepared exact target room, allows other structurally verified room
  windows to remain untouched, never activates or mutates AX focus/selection,
  and sends only through one exact AXPress-capable Send control.
- `StateStore` is an encrypted SQLCipher database for send attempts, allowlist,
  raw/normalized archive data, content hashes, configuration, and webhook
  outbox.
- `DatabaseChangeMonitor` watches the source DB/WAL and reconciles every 60s.
- `DatabaseLocator` caches only a mode-0600 source path/user ID and derives the
  source SQLCipher key in memory; normal resolution never uses Keychain.
- `StateKeyStore` atomically creates and validates the separate 32-byte state
  key as a user-owned mode-0600 `~/.kakaocli/state.key` file; normal runtime
  paths contain no Keychain or authentication-context calls.
- `LocalServiceServer` uses a same-user, mode-0600 framed Unix socket, a
  lifetime lock, bounded concurrent handlers, and serializes database work
  through the actor.
- `LegacyMigrator` imports prior local data idempotently and does not import or
  replay webhook state.
- `ConfirmedReceiptImporter` restores idempotency only after read-only proof of
  the exact outgoing row; it never invokes the UI.

## Database facts

- SQLCipher compatibility 3 is preferred, with compatibility 4 fallback.
- Kakao container: `com.kakao.KakaoTalkMac`.
- Database files may have raw hexadecimal names without `.db`.
- The local source DB is always opened read-only.
- Exact send confirmation compares `CAST(message AS BLOB)` after the target
  chat's own high-water mark, requires the logged-in author ID, and allows one
  request ID to claim each confirmed log ID.
- Self-chat is Kakao chat type 5 and its UI row has one `badge me` image.
- Group names may require `NTChatMeta` or decoded binary-plist member IDs.

## Verification before release

Run the unit suite, release build, `git diff --check`, a secret scan, the active
surface product-neutral guard, exact warm-up source/symbol guards, CLI
help/dry-run checks, socket permission and warm-service timing checks, and
release binary size check. Live warm-up validation composes/sends nothing; live
send validation is self-chat only and must independently confirm the database
row after the prior foreground app is restored.
