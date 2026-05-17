#!/bin/bash
# TDD: boot-inject.sh and session-end.sh must derive PROJECT_HASH via the
# shared _mp_hash shim (sourced from _lib.sh), NOT the legacy non-portable
# `md5 | head -c 8` pipeline. Structural regression guard so the wiring
# cannot silently revert and reintroduce the Linux silent-amnesia bug.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HERE/../hooks"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }

for f in boot-inject.sh session-end.sh; do
  p="$HOOKS/$f"
  [ -f "$p" ] || { bad "$f exists"; continue; }

  if grep -q '\. "\$SCRIPT_DIR/_lib.sh"' "$p"; then
    ok "$f sources _lib.sh via SCRIPT_DIR"
  else
    bad "$f sources _lib.sh via SCRIPT_DIR"
  fi

  if grep -Eq 'PROJECT_HASH=\$\(printf .%s. "\$PROJECT_KEY" \| _mp_hash\)' "$p"; then
    ok "$f derives PROJECT_HASH via _mp_hash"
  else
    bad "$f derives PROJECT_HASH via _mp_hash"
  fi

  if grep -q 'md5 | head -c 8' "$p"; then
    bad "$f still contains legacy 'md5 | head -c 8'"
  else
    ok "$f legacy 'md5 | head -c 8' removed"
  fi
done

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fail FAILED"; exit 1; fi
