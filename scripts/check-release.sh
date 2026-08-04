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

if rg -n --fixed-strings --glob '*.swift' \
  -e '.activate(' \
  -e 'activateIgnoringOtherApps' \
  -e 'kAXRaiseAction' \
  -e 'kAXMainAttribute' \
  -e 'kAXFocusedWindowAttribute' \
  -e 'kAXFocusedAttribute' \
  -e 'kAXSelectedRowsAttribute' \
  -e 'makeKeyAndOrderFront' \
  -e 'orderFront' \
  -e 'openApplication' \
  -e 'launchApplication' \
  -e 'CGWarpMouseCursorPosition' \
  -e 'CGDisplayMoveCursorToPoint' \
  -e 'CGAssociateMouseAndMouseCursorPosition' \
  -e 'CGEventTapPostEvent' \
  -e 'CGEvent(' \
  -e 'postToPid(' \
  -e '.post(tap:' \
  -e 'mouseEventSource:' \
  -e '--foreground' Sources; then
  print -u2 'unsafe UI primitive found in active Swift source'
  exit 1
fi

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

if nm -u .build/release/kakaocli | rg '_CGEventPost|_CGWarpMouseCursorPosition'; then
  print -u2 'keyboard/mouse event or cursor symbol found in release binary'
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
