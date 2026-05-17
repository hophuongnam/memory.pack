#!/bin/bash
# TDD: portable, value-preserving hash shim (_mp_hash) used to derive
# PROJECT_HASH in boot-inject.sh / session-end.sh.
#
# The hash MUST stay byte-identical to the legacy expression
#   printf '%s' "$KEY" | md5 | head -c 8
# so existing .boot-context-<hash> / .skip-replay-<hash> sentinels and the
# independent statusline-command.sh derivation keep matching across the
# md5 (macOS) / md5sum (Linux) split. Value-preservation is the contract;
# MD5 is tool-independent, so this is achievable.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../hooks/_lib.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      expected[%s] got[%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# --- contract: lib loads and defines _mp_hash ---
if [ ! -f "$LIB" ]; then
  echo "FAIL  hooks/_lib.sh missing ($LIB)"; exit 1
fi
# shellcheck disable=SC1090
. "$LIB"
if ! command -v _mp_hash >/dev/null 2>&1; then
  echo "FAIL  _mp_hash not defined after sourcing _lib.sh"; exit 1
fi

# --- pinned ground-truth vectors (platform-independent) ---
# MD5("") = d41d8cd98f00b204e9800998ecf8427e
chk "md5('') first8" "d41d8cd9" "$(printf '' | _mp_hash)"
# Realistic production key; hash captured from the live legacy
# `printf '%s' KEY | md5 | head -c 8` on this Mac, 2026-05-18.
RK="/Users/namhp/.claude/projects/-Users-namhp-Resilio-Sync-Management"
chk "real project key" "61a15022" "$(printf '%s' "$RK" | _mp_hash)"

# --- dynamic parity vs the EXACT legacy expression (mac-only: needs md5) ---
if command -v md5 >/dev/null 2>&1; then
  while IFS= read -r in; do
    exp=$(printf '%s' "$in" | md5 | head -c 8)
    got=$(printf '%s' "$in" | _mp_hash)
    chk "parity vs legacy md5|head -c8 [$in]" "$exp" "$got"
  done <<EOF
$(printf '\nhello\n%s\n/tmp/x y/z.dot' "$RK")
EOF
else
  echo "SKIP  dynamic md5 parity (no md5 binary - non-macOS)"
fi

# --- md5sum branch (GNU '<hex>  -' format) trim logic ---
# Faithful fake GNU md5sum so the md5sum code path + its 8-char trim are
# exercised even without coreutils. We are testing that `head -c 8` lands
# the right chars given GNU's two-space + dash suffix, not MD5 math.
if command -v md5 >/dev/null 2>&1; then
  md5sum() { printf '%s  -\n' "$(md5)"; }
  chk "md5sum-branch real key" "61a15022" "$(printf '%s' "$RK" | _mp_hash)"
  chk "md5sum-branch md5('')"  "d41d8cd9" "$(printf '' | _mp_hash)"
  unset -f md5sum
fi

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fail FAILED"; exit 1; fi
