# AGENTS.md — kakaocli safety contract

`kakaocli` reads KakaoTalk's local database and can submit a message through
the already-rendered KakaoTalk UI. Treat sending as an irreversible action.

## Prerequisites

- macOS 14+ and KakaoTalk for Mac.
- Homebrew SQLCipher (`brew install sqlcipher`).
- Full Disk Access for database reads and Accessibility permission for sends.
- KakaoTalk must already be running with its main window rendered. A person may
  foreground it; `send` never launches, activates, or raises it.

## Read commands

```bash
kakaocli auth --refresh  # one-time identity discovery/cache refresh
kakaocli auth            # later verification uses the local identity cache
kakaocli chats --json
kakaocli messages --chat-id 123456 --json
```

The mode-0600 cache at `~/.kakaocli/source-database.json` contains only the
standardized database path and Kakao user ID. The SQLCipher key is derived in
memory and is never persisted. Expensive revision-hash recovery runs only for
an explicit `auth --refresh`. Commands never accept a database key as an
argument; an exceptional one-shot override must use `--key-stdin`.

## Sending

Resolve a chat first, then send only by the exact stable ID or to self-chat.
The message body is read from stdin so it does not enter shell history or the
process list. Every request needs a caller-generated UUID.

```bash
printf '%s' 'message' | kakaocli send --chat-id 123456 \
  --request-id 733CD21B-D240-4D52-B747-958CCAC94408 --json

printf '%s' 'self test' | kakaocli send --self \
  --request-id CE6AFCE8-A013-46F2-90D8-C3BF55319B22 --json
```

The safe send path:

- accepts only `--chat-id` or `--self`; names and substring matches are rejected;
- serializes the whole transaction across threads and processes;
- requires a database-unique display identity and the structurally verified,
  selected/current Chats table, and rejects duplicate UI rows, unrelated open
  rooms, nonempty drafts, ambiguous composers, and wrong window titles;
- permits a participant-named group with an empty source `chatName` only when
  its secure harvested title has the same complete name multiset, chat type,
  and member count as the current `displayMemberIds` and `NTUser` rows;
- may reuse exactly one open target room only when its current Kakao room and
  composition structure are certified and its composer is provably empty;
- never activates or raises KakaoTalk, moves the pointer, or posts global input;
- opens a closed exact row with a Kakao-PID-targeted Return event, aborting if
  the foreground app changes, and submits only through the same direct,
  visible, frame-contained Accessibility Send control;
- never focuses the composer and proves the foreground app remains unchanged
  through composition and the Send action;
- bounds KakaoTalk Accessibility messaging calls so a stalled AX server fails
  closed instead of hanging indefinitely;
- re-resolves the destination database identity immediately before Send;
- confirms the exact UTF-8 bytes as a new outgoing row under the intended
  `chat_id` before returning `confirmed`;
- records `unknown` durably when submission may have happened but confirmation
  cannot prove it. Replaying the same request ID performs read-only database
  reconciliation and may upgrade it to `confirmed`; it never repeats UI work.
  Never retry an `unknown` request with a new request ID.

Message bodies are limited to 64 KiB of UTF-8 and `send` never accepts a
database key in process arguments.

Reusing a request ID returns its stored receipt. Reusing it with different
contents is rejected. A precondition failure before composer mutation is safe
to correct and retry with the same request ID. Any uncertainty after composer
mutation is durably `unknown` and must not trigger another UI attempt.

## Development and release checks

```bash
swift test
swift build -c release
git diff --check
```

Live tests are self-chat only. Confirm no focus change, unrelated room closure,
or external message before installing or tagging a release.

Other commands such as `login` and `harvest` are separate legacy workflows and
may foreground KakaoTalk. They are not called by `send`.

`query` accepts exactly one SQLite read-only statement. Writes, database
attachments, and trailing statements are rejected. Remote webhook endpoints
must use HTTPS; plain HTTP is accepted only for loopback development, and every
redirect is revalidated. Harvested chat-name metadata is stored atomically with
user-only permissions and rejects symlinked state.
