---
name: kakaocli
description: Read KakaoTalk locally and send approved stdin to an exact chat ID or self-chat
version: 0.7.0
requires:
  binaries:
    - kakaocli
  platform: darwin
tags:
  - messaging
  - kakaotalk
  - korea
---

# KakaoTalk CLI Skill

Read KakaoTalk's local database and submit explicitly approved text through an
already-rendered KakaoTalk UI. The safe sender never launches, activates, or
raises KakaoTalk. A person must foreground it manually when needed.

## Read

```bash
kakaocli auth --refresh  # one-time identity/cache refresh
kakaocli auth
kakaocli chats --json
kakaocli messages --chat-id 123456 --since 1h --json
kakaocli search "keyword" --json
```

Name and substring filters may help discovery, but they are never send
destinations. Resolve and verify the stable numeric `chat_id` first.
Database keys are never command arguments; use `--key-stdin` only for an
exceptional one-shot read override.

## Send

Obtain approval for the exact message bytes and destination, generate a fresh
UUID, and pipe the message through stdin:

```bash
printf '%s' 'approved message' | kakaocli send --chat-id 123456 \
  --request-id 733CD21B-D240-4D52-B747-958CCAC94408 --json

printf '%s' 'self test' | kakaocli send --self \
  --request-id CE6AFCE8-A013-46F2-90D8-C3BF55319B22 --json
```

The safe path accepts only `--chat-id` or `--self`, requires one certified
current Chats table and UI/database identity, rejects unrelated rooms and
nonempty drafts, and may reuse one exact target room with an empty certified
composer. It never focuses the composer, keeps the foreground app unchanged,
uses one direct verified Send control, and confirms exact new outgoing bytes
under that same chat ID. Message bodies are limited to 64 KiB.

A group whose source `chatName` is empty is eligible only when its secure
harvested title exactly matches the current full participant-name multiset,
member IDs, chat type, and member count. Any mismatch fails before composition.

Treat only `confirmed` with the intended `chat_id` and non-null `log_id` as
delivered. If the result is `unknown`, never create a new request ID and never
repeat the UI action. Repeating the exact same request ID, destination, and body
performs read-only database reconciliation and may upgrade the stored receipt.

Live tests are self-chat only. Legacy `login` and `harvest` workflows are
separate and may foreground KakaoTalk; the safe `send` command never calls them.
