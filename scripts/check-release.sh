#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
cd "$repo_dir"

swift test
swift build -c release
git diff --check

if rg -n --fixed-strings --glob '*.swift' \
  -e '.activate(' \
  -e 'kAXRaiseAction' \
  -e 'CGWarpMouseCursorPosition' \
  -e '.post(tap:' \
  -e 'mouseEventSource:' \
  -e '--foreground' Sources; then
  print -u2 'unsafe UI primitive found in active Swift source'
  exit 1
fi

if nm -u .build/release/kakaocli | rg '_CGEventPost$|_CGWarpMouseCursorPosition'; then
  print -u2 'global event or cursor symbol found in release binary'
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
fi

binary_bytes="$(stat -f '%z' .build/release/kakaocli)"
if (( binary_bytes >= 5 * 1024 * 1024 )); then
  print -u2 "release binary is too large: $binary_bytes bytes"
  exit 1
fi

print "release checks passed; binary_bytes=$binary_bytes"
