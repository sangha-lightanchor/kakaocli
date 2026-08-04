#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
cd "$repo_dir"

required_commands=(swift git rg nm otool xcrun stat)
for required_command in "${required_commands[@]}"; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    print -u2 "required release tool is missing: $required_command"
    exit 1
  fi
done

swift test
swift build -c release
git diff --check

warmup_source='Sources/KakaoCore/Automation/ForegroundRoomWarmup.swift'

if rg -n --fixed-strings --glob '*.swift' \
  -e 'activateIgnoringOtherApps' \
  -e 'activateAllWindows' \
  -e 'kAXRaiseAction' \
  -e 'kAXMainAttribute' \
  -e 'kAXFocusedWindowAttribute' \
  -e 'makeKeyAndOrderFront' \
  -e 'orderFront' \
  -e 'orderFrontRegardless' \
  -e 'orderWindow' \
  -e 'orderBack' \
  -e 'orderOut' \
  -e 'openApplication' \
  -e 'launchApplication' \
  -e 'NSWorkspace.shared.open' \
  -e '/usr/bin/open' \
  -e 'NSAppleScript' \
  -e 'osascript' \
  -e 'SetFrontProcess' \
  -e 'TransformProcessType' \
  -e 'AXRaise' \
  -e 'CGWarpMouseCursorPosition' \
  -e 'CGDisplayMoveCursorToPoint' \
  -e 'CGAssociateMouseAndMouseCursorPosition' \
  -e 'CGEventTapPostEvent' \
  -e 'CGEventPost(' \
  -e 'CGEventPostToPid(' \
  -e 'CGEventPostToPSN(' \
  -e 'CGPostKeyboardEvent(' \
  -e 'CGPostMouseEvent(' \
  -e 'AXUIElementPostKeyboardEvent(' \
  -e 'CGEvent(' \
  -e 'postToPid(' \
  -e 'kAXFocusedAttribute' \
  -e 'kAXSelectedRowsAttribute' \
  -e '.post(tap:' \
  -e 'mouseEventSource:' \
  -e '--foreground' Sources; then
  print -u2 'unsafe UI primitive found in active Swift source'
  exit 1
fi

foreground_sources=(${(f)"$(rg -l --fixed-strings --glob '*.swift' \
  -e '.activate(' Sources)"})
for foreground_source in "${foreground_sources[@]}"; do
  if [[ "$foreground_source" != "$warmup_source" ]]; then
    print -u2 "foreground warm-up primitive escaped into $foreground_source"
    exit 1
  fi
done
for warmup_guard in \
  'kakao.application.activate(from: prior.application, options: [])' \
  'prior.application.activate(from: kakao.application, options: [])' \
  'AXHelpers.perform(rowCell, kAXShowMenuAction as String)' \
  'AXHelpers.perform(openItem, kAXPressAction as String)' \
  'baseline.rooms.allSatisfy({ room in' \
  'AXHelpers.isCleanCompositionRoom(room.window, composer: room.composer)' \
  'bundle.localizedString(' \
  'ChatTab_Rightclick_GoChatRoom'; do
  if ! rg -q --fixed-strings "$warmup_guard" "$warmup_source"; then
    print -u2 "foreground warm-up guard is missing: $warmup_guard"
    exit 1
  fi
done
if rg -n --fixed-strings 'for localization in bundle.localizations' "$warmup_source"; then
  print -u2 'warm-up accepts inactive localization menu titles'
  exit 1
fi
if [[ "$(rg -o --fixed-strings '.activate(' "$warmup_source" | wc -l | tr -d ' ')" != 2 ]] || \
   [[ "$(rg -o --fixed-strings 'AXHelpers.perform(' "$warmup_source" | wc -l | tr -d ' ')" != 3 ]] || \
   [[ "$(rg -o --fixed-strings 'kAXShowMenuAction' "$warmup_source" | wc -l | tr -d ' ')" != 2 ]] || \
   [[ "$(rg -o --fixed-strings 'kAXPressAction' "$warmup_source" | wc -l | tr -d ' ')" != 2 ]] || \
   [[ "$(rg -o --fixed-strings 'kAXCancelAction' "$warmup_source" | wc -l | tr -d ' ')" != 2 ]]; then
  print -u2 'foreground warm-up capability counts changed'
  exit 1
fi
if rg -n --fixed-strings \
  -e 'AXHelpers.setValue' \
  -e 'AXUIElementSetAttributeValue' \
  -e 'AXUIElementPerformAction' \
  -e 'kAXValueAttribute' \
  -e 'sendControlCandidates' \
  -e 'SendRequest' \
  -e 'CGEvent' \
  -e 'postToPid' \
  -e 'keyboardSetUnicodeString' \
  -e 'setIntegerValueField' \
  -e '.flags' "$warmup_source"; then
  print -u2 'foreground warm-up contains a delivery capability'
  exit 1
fi

sender_source='Sources/KakaoCore/Automation/SafeKakaoSender.swift'
helpers_source='Sources/KakaoCore/Automation/AXHelpers.swift'
for sender_guard in \
  'AXHelpers.isCleanCompositionRoom(room, composer: composer)' \
  'return AXHelpers.children(room).filter'; do
  if ! rg -q --fixed-strings "$sender_guard" "$sender_source"; then
    print -u2 "background sender structural guard is missing: $sender_guard"
    exit 1
  fi
done
for composition_guard in \
  'fixedLeaves.count == 6' \
  'sliderIsClean' \
  'nestedButtonIsClean' \
  'composerChild.map({ CFEqual($0, composer) }) == true'; do
  if ! rg -q --fixed-strings "$composition_guard" "$helpers_source"; then
    print -u2 "clean-composition structural guard is missing: $composition_guard"
    exit 1
  fi
done
for validator_guard in \
  'guard evidence.directChildCount == 18' \
  'evidence.identifierlessButtonCount == 9' \
  'evidence.emptyIdentifierlessButtonCount == 8' \
  'evidence.nestedIdentifierlessButtonCount == 1' \
  'evidence.composerIsOnlyScrollChild' \
  'evidence.composerIsLeaf'; do
  if ! rg -q --fixed-strings "$validator_guard" "$sender_source"; then
    print -u2 "clean-composition validator guard is missing: $validator_guard"
    exit 1
  fi
done
for composer_identifier in \
  '_NS:29' '_NS:164' '_NS:144' '_NS:10' '_NS:30' \
  '_NS:42' '_NS:78' '_NS:182' '_NS:47'; do
  if ! rg -q --fixed-strings "$composer_identifier" "$sender_source"; then
    print -u2 "clean-composer identifier is missing: $composer_identifier"
    exit 1
  fi
done
for send_control_guard in \
  'AXHelpers.identifier(element) == nil' \
  'SendUIValidator.isExplicitlyVisible(' \
  'hidden == false' \
  'AXHelpers.hasContainedFrame(element, in: room)' \
  'if !actionAttempted, composerMutationAttempted' \
  'if currentValue == body'; do
  if ! rg -q --fixed-strings "$send_control_guard" "$sender_source"; then
    print -u2 "exact Send-control guard is missing: $send_control_guard"
    exit 1
  fi
done

for lock_source in \
  'Sources/KakaoCore/FileLock.swift' \
  'Sources/KakaoCore/Service/LocalService.swift'; do
  if ! rg -q --fixed-strings 'st_nlink == 1' "$lock_source"; then
    print -u2 "hard-link rejection is missing from $lock_source"
    exit 1
  fi
done
if rg -n --fixed-strings \
  -e 'currentValue?.isEmpty == true' \
  -e 'public final class SafeKakaoSender' \
  -e 'public func submit(chat: Chat, body: String)' "$sender_source"; then
  print -u2 'background transport bypass or unsafe empty-composer cleanup found'
  exit 1
fi

if [[ "$(rg -o --fixed-strings 'AXUIElementPerformAction(' Sources --glob '*.swift' | wc -l | tr -d ' ')" != 1 ]] || \
   [[ "$(rg -o --fixed-strings 'AXUIElementSetAttributeValue(' Sources --glob '*.swift' | wc -l | tr -d ' ')" != 1 ]] || \
   ! rg -q --fixed-strings 'AXUIElementPerformAction(' "$helpers_source" || \
   ! rg -q --fixed-strings 'AXUIElementSetAttributeValue(' "$helpers_source"; then
  print -u2 'direct Accessibility mutation escaped the helper boundary'
  exit 1
fi
if [[ "$(rg -o --fixed-strings 'AXHelpers.perform(' Sources --glob '*.swift' | wc -l | tr -d ' ')" != 4 ]] || \
   [[ "$(rg -o --fixed-strings 'AXHelpers.perform(' "$warmup_source" | wc -l | tr -d ' ')" != 3 ]] || \
   [[ "$(rg -o --fixed-strings 'AXHelpers.perform(' "$sender_source" | wc -l | tr -d ' ')" != 1 ]] || \
   [[ "$(rg -o --fixed-strings 'AXHelpers.setValue(' Sources --glob '*.swift' | wc -l | tr -d ' ')" != 2 ]] || \
   [[ "$(rg -o --fixed-strings 'AXHelpers.setValue(' "$sender_source" | wc -l | tr -d ' ')" != 2 ]]; then
  print -u2 'Accessibility helper call sites changed'
  exit 1
fi
for sender_action in \
  'AXHelpers.perform(control, kAXPressAction as String)' \
  'AXHelpers.setValue(composer, body)' \
  'AXHelpers.setValue(composer, "")'; do
  if ! rg -q --fixed-strings "$sender_action" "$sender_source"; then
    print -u2 "exact sender action is missing: $sender_action"
    exit 1
  fi
done

if rg -n --fixed-strings --glob '*.swift' \
  -e '/usr/bin/security' \
  -e 'find-generic-password' \
  -e 'com.kakaocli.sqlcipher' \
  -e 'LocalAuthentication' \
  -e 'SecItem' Sources; then
  print -u2 'prompt-capable or persistent Keychain access found'
  exit 1
fi
for state_key_guard in 'lstat(' 'fstat(' 'geteuid()' 'O_NOFOLLOW' 'O_EXCL' 'fsync(' '0o600'; do
  if ! rg -q --fixed-strings "$state_key_guard" Sources/KakaoCore/StateKeyStore.swift; then
    print -u2 "state-key file guard is missing: $state_key_guard"
    exit 1
  fi
done

undefined_symbols="$(nm -u .build/release/kakaocli)"
if print -r -- "$undefined_symbols" | rg \
  '_CGEventPost|_CGEventTapPostEvent|_CGPostKeyboardEvent|_CGPostMouseEvent|_AXUIElementPostKeyboardEvent|_CGWarpMouseCursorPosition|_CGDisplayMoveCursorToPoint|_CGAssociateMouseAndMouseCursorPosition|_SetFrontProcess|_TransformProcessType'; then
  print -u2 'event-posting, cursor, or front-process symbol found in release binary'
  exit 1
fi

if .build/release/kakaocli send --help | rg -n -- '--key([ ,>]|$)'; then
  print -u2 'database key must not be accepted through argv'
  exit 1
fi
if ! .build/release/kakaocli auth --help | rg -q -- '--key-stdin'; then
  print -u2 'safe stdin database-key setup command is missing'
  exit 1
fi
if ! .build/release/kakaocli migrate confirmed-receipt --help | rg -q -- '--request-id'; then
  print -u2 'verified confirmed-receipt recovery command is missing'
  exit 1
fi
if ! .build/release/kakaocli --help | rg -q 'warmup'; then
  print -u2 'exact-ID warm-up command is missing'
  exit 1
fi
if .build/release/kakaocli warmup --help | rg -n -- '--request-id|--stdin|--foreground|--key([ ,>]|$)'; then
  print -u2 'warm-up command exposes a message or foreground option'
  exit 1
fi

if rg -n --hidden --glob '!.git/**' --glob '!.build/**' \
  -e 'gho_[A-Za-z0-9]{20,}' \
  -e 'whsec_[A-Za-z0-9_]+' \
  -e 'AKIA[0-9A-Z]{16}' \
  -e 'Bearer [A-Za-z0-9._-]{24,}' .; then
  print -u2 'possible committed secret found'
  exit 1
fi

if [[ -n "${PROHIBITED_PRODUCT_NAME:-}" ]]; then
  active=(Sources Tests README.md AGENTS.md CLAUDE.md scripts skills assets)
  if rg -n -i --hidden --glob '!.build/**' -- "$PROHIBITED_PRODUCT_NAME" "${active[@]}"; then
    print -u2 'prohibited product reference found in an active surface'
    exit 1
  fi
elif [[ "${REQUIRE_PROHIBITED_PRODUCT_SCAN:-0}" == 1 ]]; then
  print -u2 'PROHIBITED_PRODUCT_NAME is required for this release gate'
  exit 1
fi

binary_bytes="$(stat -f '%z' .build/release/kakaocli)"
if (( binary_bytes >= 5 * 1024 * 1024 )); then
  print -u2 "release binary is too large: $binary_bytes bytes"
  exit 1
fi

sqlcipher_path="$(otool -L .build/release/kakaocli | awk '/sqlcipher/{print $1; exit}')"
if [[ -z "$sqlcipher_path" ]]; then
  print -u2 'release binary is not linked to SQLCipher'
  exit 1
fi

sqlcipher_minos='unknown'
if [[ -e "$sqlcipher_path" ]]; then
  sqlcipher_minos="$(xcrun vtool -show-build "$sqlcipher_path" 2>/dev/null | awk '/minos/{print $2; exit}')"
  [[ -n "$sqlcipher_minos" ]] || sqlcipher_minos='unknown'
fi
target_minos="$(sed -nE 's/.*\.macOS\(\.v([0-9]+)\).*/\1.0/p' Package.swift | head -1)"
[[ -n "$target_minos" ]] || target_minos='unknown'

portable=true
if [[ "$sqlcipher_path" == /* ]]; then
  portable=false
  print -u2 "source-build diagnostic: SQLCipher uses an absolute install path: $sqlcipher_path"
fi
if [[ "$sqlcipher_minos" != unknown && "$target_minos" != unknown ]]; then
  autoload -Uz is-at-least
  if ! is-at-least "$sqlcipher_minos" "$target_minos"; then
    portable=false
    print -u2 "source-build diagnostic: SQLCipher minOS $sqlcipher_minos exceeds package minOS $target_minos"
  fi
fi

if [[ "${KAKAOCLI_BINARY_RELEASE:-0}" == 1 && "$portable" != true ]]; then
  print -u2 'refusing a non-portable binary release; publish source-only or bundle a compatible @rpath SQLCipher'
  exit 1
fi

print "release checks passed; binary_bytes=$binary_bytes sqlcipher_path=$sqlcipher_path sqlcipher_minos=$sqlcipher_minos portable=$portable"
