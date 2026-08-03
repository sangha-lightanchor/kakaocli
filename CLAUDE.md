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
  `flock`, the database high-water mark, and exact post-send confirmation.
- `KakaoClient` is the public actor wrapper for reads and sends.
- `KakaoAutomator.submit` is the only send automation entry point. It operates
  on an already-rendered UI and must remain free of application activation,
  window raising, pointer movement, and global input.
- `BackgroundSendSelector` contains pure fail-closed selection rules and is
  covered by unit tests.
- `DatabaseReader.confirmedOutgoing` scopes confirmation to the intended
  `chat_id`, current user, log ID above the snapshot, and exact message bytes.

An automation error after the submit action becomes an `unknown` receipt. Never
add automatic retries for that result. Live tests must target self-chat only.
