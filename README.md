# kakaocli

`kakaocli` is a lightweight macOS Swift library and CLI for local, read-only
KakaoTalk history access, fail-closed sending, allowlisted archiving, and an
optional persistent Unix-socket service.

It is not a Kakao network API. KakaoTalk must already be running and its main
window must already be rendered before a send. The program never launches or
activates KakaoTalk, raises a window, moves the cursor, or posts global input.
If the UI cannot prove the exact destination and composer, it stops before
composing.

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

## Stable-ID CLI

Names are for discovery only. Sends accept one exact database `chat_id` or
self-chat, never a name or substring. Message content is read from stdin so it
does not enter shell history or process arguments. A caller-supplied UUID is
required and durably prevents a retry from duplicating an uncertain result.

```bash
kakaocli chats --search "Dr. Jo" --json
printf '%s' 'Approved message' | \
  kakaocli send --chat-id 123456 --stdin --request-id "$(uuidgen)" --json
printf '%s' 'Self-chat acceptance test' | \
  kakaocli send --self --stdin --request-id "$(uuidgen)" --json
kakaocli messages --chat-id 123456 --since 24h --json
```

A send receipt is either `confirmed`, with the exact new local Kakao log ID,
or `unknown`. `unknown` means the UI action may have happened but the exact
outgoing bytes did not appear under the intended chat ID before the deadline.
Do not retry it with a new request ID; inspect the chat or local database first.

The send transaction holds both the `KakaoClient` actor queue and
`~/.kakaocli/run/send.lock`. Before submitting it verifies:

- the ID exists in the local database;
- exactly one UI row represents that destination;
- no unrelated room is open;
- a reusable target room has an empty, unique composer;
- row selection, focus, newly opened title, composer identity, and exact body;
- one exact enabled Send control, or the verified focused composer before a
  Return event delivered only to KakaoTalk's process;
- the exact outgoing UTF-8 bytes appeared after the target chat's database
  high-water mark.

## Optional service

```bash
kakaocli service run
kakaocli service status
```

The service is optional and runs in the current process. It keeps one
read-only SQLCipher connection and a cached chat index, serializes sends, and
listens on `~/.kakaocli/run/kakaocli.sock` with mode `0600`. CLI read/send
commands use it when available and otherwise open a direct local client using
the same send lock.

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

State and raw attachment metadata are encrypted in
`~/.kakaocli/state.sqlite3`. Retrievable media uses HTTPS only, validates any
reported size and checksum, computes SHA-256, and deduplicates into
`~/.local/share/kakaocli/archive/objects/`. Links, previews, photos,
multi-photo messages, video, audio, files, stickers, and supported local paths
are normalized. Metadata is retained when a signed URL expires or downloads
pause for critically low disk space. There is no retention deletion job.

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

## Public Swift API

```swift
let client = try KakaoClient.live()
let chats = try await client.listChats(search: "Dr. Jo")
let receipt = try await client.send(SendRequest(
    requestID: UUID(),
    destination: .chatID(ChatID(rawValue: 123456)),
    body: "Approved message"
))
let stream = await client.events()
```

The core types are `ChatID`, `SendDestination`, `SendRequest`, `SendStatus`,
`SendReceipt`, `KakaoEvent`, and `ArchiveStatus`.

## Legacy local import

The importer is idempotent and intentionally ignores old webhook configuration
and outbox payloads:

```bash
kakaocli migrate legacy \
  --messages-db /path/to/messages.sqlite \
  --media-db /path/to/media.sqlite \
  --media-root /path/to/media/archive --json
```

Only self-chat may be used for live acceptance testing. Sending to another
person requires the operator's approval of the exact text and exact chat ID.

## License

MIT. This project is not affiliated with Kakao Corp.
