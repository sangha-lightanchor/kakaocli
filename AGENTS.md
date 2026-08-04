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
- Never launch or activate KakaoTalk, raise a window, move the cursor, or post
  global keyboard/mouse input. Users may foreground KakaoTalk themselves.
- Reject every unrelated or additional open room. Reuse one exact target-title
  room only after the database proves its display identity is globally unique,
  the exact destination row still exists once, and the room has one empty
  composer; otherwise open only the freshly verified destination row.
- Resolve an ID through the database, then require exactly one matching UI row.
  Prove the current Chats view from one direct navigation set and one
  chat-specific table schema; never treat a merely present `chatrooms` control
  or a generic table as selected-view proof.
  Verify row selection, focus, the new room title, composer identity, body, and
  focus again before invoking a control.
- Invoke only one exact enabled Send/전송 control. If it is absent, Return may
  be delivered only to KakaoTalk's PID after the exact composer remains focused.
- Snapshot the intended chat's log-ID high-water mark before composing and
  confirm exact outgoing UTF-8 bytes only under that same chat ID.
- Return `confirmed` or `unknown`. Persist both. Reusing the exact same request
  ID may only reconcile the database and must never repeat the UI action. A
  Kakao log ID may be claimed by at most one request ID. Never reuse a request
  ID with different content.
- Live tests are self-chat only. Never send a test to another person's room.

`Tests/KakaoCoreTests/SafetySourceGuardTests.swift` prevents activation,
raising, cursor, global-event, and removed-option regressions.

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
