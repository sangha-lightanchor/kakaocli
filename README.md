# kakaocli

`kakaocli` is a lightweight macOS Swift library and CLI for local, read-only
KakaoTalk history access, fail-closed sending, allowlisted archiving, and an
optional persistent Unix-socket service.

It is not a Kakao network API. KakaoTalk must already be running and its main
window must already be rendered before a send. The program never launches
KakaoTalk, raises a window, moves the cursor, or posts global input. When an
exact target room is not open, a narrowly isolated warm-up may briefly
activate KakaoTalk, open the database-resolved row's native context menu, invoke
exactly one Kakao-localized “enter chatroom” item, restore the previous app
immediately, and verify the exact new room in the background. If any identity
check fails, it stops without composing or sending.

## Requirements

- macOS 14 or newer
- KakaoTalk for Mac
- Full Disk Access for the calling terminal or service
- Accessibility permission for sending
- SQLCipher (`brew install sqlcipher`)

```bash
swift build -c release
swift test
```

Before the first normal read on a new installation, cache the local database
identity once:

```bash
kakaocli auth --refresh
```

The cache is `~/.kakaocli/source-database.json`, contains only the validated
database path and Kakao user ID, and is mode `0600`. The SQLCipher key is
derived in memory and is never stored in Keychain, a file, or process
arguments. If an exceptional recovery requires a caller-supplied key, pipe it
to `kakaocli auth --key-stdin`; that key is used once and never persisted.
The separate 32-byte encryption key for `state.sqlite3` is stored as exactly
64 hexadecimal bytes in `~/.kakaocli/state.key`, a user-owned mode-`0600`
regular file. Normal commands do not access Keychain and therefore do not open
a macOS Keychain permission dialog. Back up or move `state.key` together with
`state.sqlite3`; losing either one makes the encrypted local state unusable.

## Stable-ID CLI

Names are for discovery only. Sends accept one exact database `chat_id` or
self-chat, never a name or substring. Message content is read from stdin so it
does not enter shell history or process arguments. A caller-supplied UUID is
required and durably prevents a retry from duplicating an uncertain result.

```bash
kakaocli chats --search "Dr. Jo" --json
kakaocli warmup --chat-id 123456 --json
kakaocli warmup --self --json
printf '%s' 'Approved message' | \
  kakaocli send --chat-id 123456 --stdin --request-id "$(uuidgen)" --json
printf '%s' 'Self-chat acceptance test' | \
  kakaocli send --self --stdin --request-id "$(uuidgen)" --json
kakaocli messages --chat-id 123456 --since 24h --json
```

A send receipt is either `confirmed`, with the exact new local Kakao log ID,
or `unknown`. `unknown` means the UI action may have happened but the exact
outgoing bytes did not appear under the intended chat ID before the deadline.
Do not retry it with a new request ID. Repeating the exact request with the
same request ID performs read-only reconciliation and may upgrade the stored
receipt to `confirmed`; it never invokes the UI action again.

The send transaction holds both the `KakaoClient` actor queue and
`~/.kakaocli/run/send.lock`. Before submitting it verifies:

- the ID exists in the local database;
- the destination's display identity is unique across the source database;
- the current Chats view is jointly proven by KakaoTalk's direct navigation
  controls and one chat-only row schema, even when KakaoTalk does not expose a
  selected-state attribute, and exactly one UI row represents the destination;
- every non-main KakaoTalk window is a structurally verified room; unrelated
  rooms may remain open and must not change, and exactly one target-title room
  may exist with one empty composer; reuse leaves unrelated drafts untouched,
  while a foreground warm-up refuses to activate if another room contains a
  draft or queued/ambiguous composition state;
- when the target is closed, the separate warm-up phase records the exact prior
  foreground app, temporarily activates the one verified KakaoTalk process,
  rechecks the complete window/table/row set around each action, opens only the
  exact row-bound context menu item, verifies one exact-title room and empty
  composer, and restores the prior app before the send reservation is created;
- the same row, room, composer, exact body, foreground application, and one
  exact enabled Send control remain unchanged before AXPress;
- the exact outgoing UTF-8 bytes appeared after the target chat's database
  high-water mark.

The strict sender never activates an app, mutates Accessibility focus or
selected rows, or creates keyboard/mouse events. Temporary activation and the
exact row-menu opening action exist only in `ForegroundRoomWarmup.swift`, which
never receives message bytes and cannot discover or invoke a Send control.
`send` runs the warm-up automatically under the same actor and cross-process
lock before it snapshots the database high-water mark or reserves the request
ID.

`warmup` performs the same no-message preparation explicitly. Once opened, a
room remains reusable while KakaoTalk keeps that window open. Warm-up is needed
again only after the room is closed or KakaoTalk restarts; callers never need
to reopen each room manually. There is no `--foreground` mode.

## Optional service

```bash
kakaocli service run
kakaocli service status
```

The service is optional and runs in the current process. It keeps one
read-only SQLCipher connection, serializes database and send work through the
`KakaoClient` actor, and listens on `~/.kakaocli/run/kakaocli.sock` with mode
`0600`. It verifies the connecting process has the same effective user ID,
bounds framed requests and concurrent handlers, and holds a lifetime lock so
only one service instance can own the socket. CLI read/warm-up/send commands
use it when available and otherwise open a direct local client using the same
send lock. UI commands require local-service protocol v2; restart a service
started by an older binary before using `warmup` or `send`.

Database and WAL vnode notifications trigger debounced reads; a 60-second
reconciliation timer covers missed notifications and late local backfills.

## Allowlisted archive

No chat is archived until its exact ID is allowed:

```bash
kakaocli config allow-chat 123456
kakaocli config list --json
kakaocli archive reconcile
kakaocli archive status --json
```

Allowlisting starts at that chat's current database high-water mark; it does
not silently backfill older history. A checkpointed reconciliation then keeps
new metadata durable without a seven-day cutoff.

State and raw attachment metadata are encrypted in
`~/.kakaocli/state.sqlite3`. Retrievable media uses HTTPS only, validates any
approved Kakao-controlled public hosts, rejects unsafe redirects and local
paths, enforces size/free-space limits while streaming, validates any reported
size and checksum, computes SHA-256, and deduplicates into
`~/.local/share/kakaocli/archive/objects/`. Links, previews, photos,
multi-photo messages, video, audio, files, stickers, and supported local paths
are normalized; ordinary links and previews remain metadata-only and are never
fetched. Metadata is retained when a signed URL expires, verification fails,
or downloads pause for critically low disk space. There is no retention
deletion job.

## Generic webhooks

Webhooks are disabled until freshly configured:

```bash
printf '%s' "$TOKEN" | kakaocli config webhook \
  --url https://example.com/kakao-events --bearer-token-stdin
kakaocli config webhook --disable
```

The durable outbox sends text, normalized metadata, archive status, and hashes
with `Idempotency-Key` and `X-Kakaocli-Event-ID`. It never sends binaries,
signed CDN URLs, or local paths. HTTP is accepted only for a loopback endpoint.
Redirects are rejected so POST bodies and bearer tokens cannot cross origins.

## Public Swift API

```swift
let client = try KakaoClient.live()
let chats = try await client.listChats(search: "Dr. Jo")
let warmup = try await client.warmup(destination: .chatID(ChatID(rawValue: 123456)))
let receipt = try await client.send(SendRequest(
    requestID: UUID(),
    destination: .chatID(ChatID(rawValue: 123456)),
    body: "Approved message"
))
let stream = await client.events()
```

The core types are `ChatID`, `SendDestination`, `RoomWarmupStatus`,
`RoomWarmupReceipt`, `SendRequest`, `SendStatus`, `SendReceipt`, `KakaoEvent`,
and `ArchiveStatus`.

## Legacy local import

The importer is idempotent and intentionally ignores old webhook configuration
and outbox payloads:

```bash
kakaocli migrate legacy \
  --messages-db /path/to/messages.sqlite \
  --media-db /path/to/media.sqlite \
  --media-root /path/to/media/archive --json
```

If a state database must be reconstructed, a prior confirmed request can be
restored without sending. The command first proves that the supplied log ID is
an outgoing row in the exact chat, with exact stdin bytes; `--self` additionally
proves that the chat is the current account's self-chat:

```bash
printf '%s' 'Exact prior body' | kakaocli migrate confirmed-receipt \
  --request-id UUID --chat-id 123456 --log-id 789 --self --stdin --json
```

The recovery command only writes the local idempotency receipt. It never opens
or interacts with KakaoTalk and refuses request-ID or log-ID ownership
conflicts.

Only self-chat may be used for live acceptance testing. Sending to another
person requires the operator's approval of the exact text and exact chat ID.

## Release artifacts

Source builds are the supported distribution. The release check refuses a
binary artifact when its linked Homebrew SQLCipher path or deployment target
is not portable to the advertised macOS target.

## License

MIT. This project is not affiliated with Kakao Corp.
