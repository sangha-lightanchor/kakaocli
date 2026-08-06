# AGENTS.md — kakaocli safety contract

## Build and test

```bash
swift build
swift test
swift build -c release
```

The only package dependency is Apple's Swift Argument Parser. SQLCipher is a
Homebrew system library.

## Non-negotiable send behavior

- Sending accepts only a stable `chat_id` or `--self`. Never add name,
  substring, position, or first-match sending.
- Message content comes from stdin. Never add a positional message argument.
- Every send requires a caller-supplied UUID request ID.
- Hold the actor queue and cross-process file lock for the entire transaction,
  including database confirmation.
- Never launch KakaoTalk, raise/order a window, move the cursor, or post global
  keyboard/mouse input. Never add `--foreground`.
- Never activate KakaoTalk or navigate its chat list. The exact target room must
  already be open and its separate room window must remain open continuously
  while background send capability is needed. This is not a one-time setup:
  closing the room or restarting KakaoTalk requires reopening it before the next
  send. `OpenRoomBinding.swift` inspects only the running process and direct
  room-window set; a closed room returns `needs_user_open` before any message
  bytes are reserved or composed.
- Permit multiple open rooms only when every non-main window has the strict room
  fingerprint and stable composer. Require exactly one target-title room and an
  empty target composer. Reuse leaves unrelated drafts unchanged. The target
  may be reused whether the main Chats window is rendered or hidden. If its
  composer is empty but KakaoTalk is still
  rendering the immediate post-send transition, wait at most five seconds for
  that same window to regain the certified clean fingerprint; any non-empty
  value or identity change fails immediately without composing or sending.
- Treat `AXWindows` as usable only when every returned object has the exact
  `AXWindow` role. Malformed or empty results may fall back only to direct
  application children with that role; never accept arbitrary descendants.
- Resolve an ID through the database and require a database-unique display
  identity. Bind directly to exactly one strict exact-title room and reverify
  that same window, composer, body, foreground application, and Send control
  before invocation. Never use a list row as destination evidence for sending.
- The normal sender must never activate, mutate Accessibility focus/selection,
  or create/post keyboard or mouse events. Invoke only one exact enabled
  Send/전송 AXPress control from the prepared verified target room.
- Already-open-room binding occurs under the same actor and cross-process lock
  before the high-water snapshot and durable send reservation. Binding failure
  is no-send/retry-safe; once the reservation exists, existing unknown-outcome
  rules apply.
- Snapshot the intended chat's log-ID high-water mark before composing and
  confirm exact outgoing UTF-8 bytes only under that same chat ID.
- Never treat KakaoTalk's temporary outgoing-row ID `Int64.max` as a message,
  high-water mark, or confirmed receipt. Wait for the durable server log ID;
  demote any legacy sentinel receipt to `unknown` for same-UUID read-only
  reconciliation.
- Return `confirmed` or `unknown`. Persist both. Reusing the exact same request
  ID may only reconcile the database and must never repeat the UI action. A
  Kakao log ID may be claimed by at most one request ID. Never reuse a request
  ID with different content.
- Live tests are self-chat only. Never send a test to another person's room.

`Tests/KakaoCoreTests/SafetySourceGuardTests.swift` prohibits activation,
row-menu opening, focus/selection mutation, keyboard/global input, raising,
cursor movement, and delivery capability in the open-room binder.

## Archive and service

- The optional service owns one read-only Kakao SQLCipher connection, listens
  on a user-only Unix socket, and uses the same send file lock as direct CLI
  calls.
- Watch the database and WAL with debounced vnode notifications and a
  60-second reconciliation backstop. Do not restore rapid polling.
- Archive only explicitly allowlisted chat IDs.
- Keep raw attachment metadata only in encrypted state. Normalize links,
  previews, photos, multi-photo, video, audio, files, stickers, and supported
  local paths.
- Media retrieval is HTTPS-only. Verify reported byte count/checksum, compute
  SHA-256, enforce approved-host, redirect, size, local-path, and free-space
  policy, and deduplicate into content-addressed storage. Ordinary links and
  previews are metadata-only.
- Retain metadata on expiration, verification failure, or low disk. Never
  delete retained messages/media automatically.
- Webhooks remain disabled until freshly configured. Payloads may contain text,
  normalized metadata, archive status, and hashes; never binaries, signed CDN
  URLs, or local paths. Use the durable outbox and idempotency headers.

## Local paths

- state/config: `~/.kakaocli/`
- socket: `~/.kakaocli/run/kakaocli.sock`
- media: `~/.local/share/kakaocli/archive/`

Machine-specific IDs, database keys, state keys, and webhook secrets stay
local and uncommitted.

Normal source-database resolution caches only a mode-0600 path and user ID and
derives the SQLCipher key in memory. It never reads or writes a source key in
Keychain. The separate state-database key lives only in the user-owned,
mode-0600 regular file `~/.kakaocli/state.key`; it must be moved or backed up
with `state.sqlite3`. Never add Keychain access to a normal runtime path.
State recovery may restore a confirmed receipt only after proving the exact
outgoing log row, chat ID, current-user authorship, and stdin bytes from the
read-only source database; it must never invoke the UI.
