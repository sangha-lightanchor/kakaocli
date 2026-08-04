---
name: kakaocli
description: Read local KakaoTalk history by stable chat ID and safely send approved stdin to an exact chat ID or self-chat.
---

# kakaocli

Use `kakaocli chats --search "name" --json` only to discover the stable ID.
Read with `kakaocli messages --chat-id ID --since 24h --json`.

For any non-self send, obtain approval of the exact message and exact chat ID.
Then pipe the exact UTF-8 message through stdin and supply a fresh UUID:

```bash
printf '%s' 'approved exact text' | \
  kakaocli send --chat-id 123456 --stdin --request-id "$(uuidgen)" --json
```

Live testing is self-chat only:

```bash
printf '%s' 'self-chat test' | \
  kakaocli send --self --stdin --request-id "$(uuidgen)" --json
```

Treat `confirmed` as delivered only after its `log_id` is present. Treat
`unknown` as possibly delivered: never retry it automatically or with a new
request ID. Repeating the exact request with the same request ID performs
read-only reconciliation and never invokes another UI action.

Never try to make KakaoTalk visible through automation. If kakaocli reports
that the app or main window is unavailable, ask the user to foreground it
manually and leave the window rendered.

If local database identity has not been cached, run `kakaocli auth --refresh`
once. Normal reads never request the Kakao SQLCipher key from Keychain. Do not
work around Keychain prompts by broadening partition lists or access for other
applications. The encrypted local state uses `~/.kakaocli/state.key`, which is
a user-owned mode-`0600` file and must be backed up with `state.sqlite3`.
If state recovery is required, use `kakaocli migrate confirmed-receipt` only
with the exact prior body on stdin. It proves the outgoing source row and never
invokes the UI.

Archive access is explicit:

```bash
kakaocli config allow-chat 123456
kakaocli archive status --json
```
