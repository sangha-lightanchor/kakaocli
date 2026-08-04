# CLAUDE.md

Follow [AGENTS.md](AGENTS.md), especially its irreversible-send safety contract.

## Build

```bash
swift build
swift test
```

The package requires Homebrew SQLCipher and uses Swift Argument Parser.

## Safe sender architecture

- `SafeSendClient` owns idempotency, the in-process lock, the cross-process
  `flock`, fresh database identity resolution, database-wide UI-label
  uniqueness, the per-chat high-water mark, unique confirmed-log ownership,
  and exact post-send confirmation.
- `KakaoClient` is the public actor wrapper for reads and sends.
- The internal `KakaoAutomator` is the only send transport. Public callers
  cannot bypass `SafeSendClient` locking, request IDs, durable receipts, or
  database confirmation. It operates on an already-rendered UI and must remain
  free of application activation, window raising, pointer movement, and global
  input.
- `BackgroundSendSelector` contains pure fail-closed selection rules and is
  covered by unit tests. The send path accepts only a certified current Chats
  table and may reuse exactly one certified target room with an empty composer;
  unrelated rooms and drafts fail closed.
- `DatabaseReader.confirmedOutgoing` scopes confirmation to the intended
  `chat_id`, current user, log ID above the snapshot, and exact message bytes.
- `DatabaseLocator` caches only a mode-0600 database path/user-ID identity. It
  derives the SQLCipher key in memory; expensive identity recovery is explicit
  through `kakaocli auth --refresh`.

An automation error after the submit action becomes an `unknown` receipt.
Replaying the exact request ID may reconcile it from the database but must
never repeat UI work. Never add automatic retries for that result. Live tests
must target self-chat only.
