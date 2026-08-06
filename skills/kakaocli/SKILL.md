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

To verify a room is already open without composing or sending:

```bash
kakaocli warmup --chat-id 123456 --json
kakaocli warmup --self --json
```

Treat `confirmed` as delivered only after its `log_id` is present. Treat
`unknown` as possibly delivered: never retry it automatically or with a new
request ID. Repeating the exact request with the same request ID performs
read-only reconciliation and never invokes another UI action.

KakaoTalk must already be running. An already-open exact target room can be
reused whether the main Chats window is rendered or hidden. Its separate room
window must remain open continuously while background send capability is
needed; opening it is not a permanent one-time setup. If the exact room is
closed or KakaoTalk restarts, the command returns `needs_user_open`; reopen the
room manually, leave it open, and retry. Never add or invent a `--foreground`
option.

`send` binds the database-unique identity directly to one strict exact-title
room. It never activates KakaoTalk or navigates the main chat list. Other
structurally verified rooms remain untouched, unrelated drafts are left
unchanged, and no main-window row is required. An empty target composer may
wait up to five seconds for KakaoTalk's immediate post-send controls to settle;
a non-empty composer or identity change fails closed.
The strict sender itself is control-only and uses only the exact target room's
verified Send control without changing the foreground application.
Window discovery accepts only exact `AXWindow` objects, including when KakaoTalk
temporarily returns malformed non-window objects through `AXWindows`.

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
