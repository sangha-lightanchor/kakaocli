# CLAUDE.md

Follow the complete shared safety contract in `AGENTS.md`.

## Architecture

- `KakaoClient` is the concurrency-safe public actor and owns the persistent
  read-only database connection, cache, send queue, events, and archive work.
- `SafeSendCoordinator` owns request validation, idempotency, the full send
  lock, high-water snapshot, exact-byte confirmation, and receipts.
- `SafeKakaoSender` is the only send UI transport. Its pre-action failures prove
  no action occurred; post-control uncertainty becomes `unknown`.
- `StateStore` is an encrypted SQLCipher database for send attempts, allowlist,
  raw/normalized archive data, content hashes, configuration, and webhook
  outbox.
- `DatabaseChangeMonitor` watches the source DB/WAL and reconciles every 60s.
- `LocalServiceServer` uses a mode-0600 Unix socket and serializes calls through
  the actor.
- `LegacyMigrator` imports prior local data idempotently and does not import or
  replay webhook state.

## Database facts

- SQLCipher compatibility 3 is preferred, with compatibility 4 fallback.
- Kakao container: `com.kakao.KakaoTalkMac`.
- Database files may have raw hexadecimal names without `.db`.
- The local source DB is always opened read-only.
- Exact send confirmation compares `CAST(message AS BLOB)` after the target
  chat's own high-water mark and requires the logged-in author ID.
- Self-chat is Kakao chat type 5 and its UI row has one `badge me` image.
- Group names may require `NTChatMeta` or decoded binary-plist member IDs.

## Verification before release

Run the unit suite, release build, `git diff --check`, a secret scan, the active
surface product-neutral guard, CLI help/dry-run checks, socket permission and
warm-service timing checks, and release binary size check. Live validation is
self-chat only and must independently confirm the database row while another
app remains frontmost.
