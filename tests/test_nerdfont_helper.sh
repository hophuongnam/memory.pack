#!/bin/bash
# TDD: _mp_have_nerdfont honors MEMORY_PACK_NERDFONT override (1/0/true/false/yes/no)
# and falls back to `fc-list :family | grep -qi 'nerd'` probe. Returns 0/1 exit
# code. No stdout. Pinned because statusline-icons.sh sources _lib.sh and
# branches on this helper to pick the Nerd vs Unicode glyph table.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../hooks/_lib.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }

[ -f "$LIB" ] || { echo "FAIL  _lib.sh missing"; exit 1; }

# shellcheck disable=SC1090
. "$LIB"

type _mp_have_nerdfont >/dev/null 2>&1 && ok "_mp_have_nerdfont defined" || bad "_mp_have_nerdfont defined"

# Env override: explicit 1/true/yes returns 0
for v in 1 true yes; do
  MEMORY_PACK_NERDFONT="$v" _mp_have_nerdfont 2>/dev/null \
    && ok "env=$v returns 0" || bad "env=$v returns 0"
done

# Env override: explicit 0/false/no returns 1
for v in 0 false no; do
  if MEMORY_PACK_NERDFONT="$v" _mp_have_nerdfont 2>/dev/null; then
    bad "env=$v returns 1"
  else
    ok "env=$v returns 1"
  fi
done

# Empty env: falls through to fc-list probe. We don't assert the outcome
# (depends on host) — just that the call doesn't crash and returns 0 or 1.
MEMORY_PACK_NERDFONT="" _mp_have_nerdfont >/dev/null 2>&1
rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; } && ok "empty env returns 0 or 1" || bad "empty env returns 0 or 1 (got $rc)"

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
