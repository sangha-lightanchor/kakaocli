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
- Reject unrelated open rooms. Reuse one exact target room only when it has one
  verified empty composer.
- Resolve an ID through the database, then require exactly one matching UI row.
  Verify row selection, focus, the new room title, composer identity, body, and
  focus again before invoking a control.
- Invoke only one exact enabled Send/전송 control. If it is absent, Return may
  be delivered only to KakaoTalk's PID after the exact composer remains focused.
- Snapshot the intended chat's log-ID high-water mark before composing and
  confirm exact outgoing UTF-8 bytes only under that same chat ID.
- Return `confirmed` or `unknown`. Persist both. Never automatically retry an
  `unknown` result, and never reuse a request ID with different content.
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
  SHA-256, and deduplicate into content-addressed storage.
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
