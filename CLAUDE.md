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
- `SafeSendClient.preflight` verifies a database-unique, visible row and one
  already-open exact background room without composing, posting Return, or
  creating a receipt. Self-chat may instead use one exact selected
  badge-marked row in the verified Friends identity table. First-attempt sends
  perform that preflight before the durable unknown reservation.
- `BackgroundSendSelector` contains pure fail-closed selection rules and is
  covered by unit tests. External sends accept only a certified current Chats
  table. Every open room must have a unique nonempty title, certified current
  or legacy Kakao 26.x chrome, and one empty composer; unrelated rooms are
  snapshotted and must remain unchanged and unfocused. Closed targets,
  foreground KakaoTalk, ambiguous rooms, and drafts fail closed.
- The sender is pinned to KakaoTalk `26.6.1 (1190)`. After exact identity proof
  it may set the target as Kakao's internal main window and first responder,
  while proving the OS foreground PID never changes. It keeps the exact Send
  control as an identity/stability anchor, does not press it, and posts Return
  only to KakaoTalk's PID. Composer re-instantiation is accepted only under the
  same exact container, child order, certified chrome, focus, and body.
- `DatabaseReader.confirmedOutgoing` scopes confirmation to the intended
  `chat_id`, current user, log ID above the snapshot, and exact message bytes.
- `DatabaseReader` resolves participant-named groups with an empty source
  `chatName` only when secure harvested metadata exactly matches the current
  binary-plist `displayMemberIds`, `NTUser` names, chat type, and member count.
  The ordinary exact-row/window checks still apply to the resulting title.
- `DatabaseLocator` caches only a mode-0600 database path/user-ID identity. It
  derives the SQLCipher key in memory; expensive identity recovery is explicit
  through `kakaocli auth --refresh`.
- Database-key overrides are stdin-only. `DatabaseReader` uses the typed
  SQLCipher key API, accepts only a user-owned regular source file, enables
  query-only mode, and rejects writable, attached, or multi-statement raw SQL.
- Remote webhooks require HTTPS except for loopback development endpoints and
  must not contain URL credentials; redirect targets are revalidated before
  following them.
- Harvest metadata is atomically persisted as a mode-0600 user-owned regular
  file. Symlinked or corrupt metadata state fails closed.

An automation error after the submit action becomes an `unknown` receipt.
Replaying the exact request ID may reconcile it from the database but must
never repeat UI work. Never add automatic retries for that result. Live tests
must target self-chat only.
