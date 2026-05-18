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

# --- python3 fallback: NEITHER md5sum NOR md5 present --------------------
# Windows / minimal-host case. python3 is a hard install dependency, so
# _mp_hash must still emit the byte-identical 8-hex via python3 when no
# md5 CLI exists — otherwise PROJECT_HASH is silently empty and every
# .boot-context-<hash>/.skip-replay-<hash> sentinel orphans (the exact
# silent-amnesia class this shim exists to kill). Sandbox PATH = python3
# only; run in a child shell so the faked md5sum() above can't leak in.
# Shadow the `command` builtin to control which hash tools _mp_hash "sees"
# as installed, WITHOUT touching PATH (PATH-nuking breaks pyenv/env-shim
# python3 itself — an artifact unrelated to the branch logic under test).
# Real PATH stays intact, so the real python3 computes the real MD5 and we
# still assert the real byte-identical value. Same environment-injection
# idiom as test_sdk_resolve.mjs's DI'd `exists` and the md5sum() shadow.
HIDE_MD5='command() { case "$2" in md5sum|md5) return 1;; esac; builtin command "$@"; };'
HIDE_ALL='command() { case "$2" in md5sum|md5|python3) return 1;; esac; builtin command "$@"; };'

# --- python3 fallback: md5sum + md5 hidden, python3 still present --------
if command -v python3 >/dev/null 2>&1; then
  got=$(printf '%s' "$RK" | bash -c "$HIDE_MD5"' . "'"$LIB"'"; _mp_hash')
  chk "python3-only: real project key" "61a15022" "$got"
  gote=$(printf '' | bash -c "$HIDE_MD5"' . "'"$LIB"'"; _mp_hash')
  chk "python3-only: md5('')" "d41d8cd9" "$gote"
else
  echo "SKIP  python3-only path (no python3 on this host)"
fi

# --- loud-fail invariant: ALL three hidden ------------------------------
# Must emit empty stdout, non-zero return, AND a non-empty stderr reason.
# A silent empty hash is the amnesia bug; this guards the invariant across
# the branch reorder.
out=$(printf '%s' "$RK" | bash -c "$HIDE_ALL"' . "'"$LIB"'"; _mp_hash' 2>/dev/null)
err=$(printf '%s' "$RK" | bash -c "$HIDE_ALL"' . "'"$LIB"'"; _mp_hash' 2>&1 1>/dev/null)
rc=0; printf '%s' "$RK" | bash -c "$HIDE_ALL"' . "'"$LIB"'"; _mp_hash' >/dev/null 2>&1 || rc=$?
chk "loud-fail: empty stdout when no tool" "" "$out"
if [ "$rc" -ne 0 ]; then ok "loud-fail: non-zero return when no tool"
else bad "loud-fail: non-zero return when no tool" "rc!=0" "rc=$rc"; fi
if [ -n "$err" ]; then ok "loud-fail: stderr explains the failure"
else bad "loud-fail: stderr explains the failure" "non-empty" "empty"; fi

# --- statusline-command.sh derives the SAME hash as _mp_hash ------------
# Contract (see header): statusline's independent derivation must match
# _mp_hash byte-for-byte, else the ⏭skip-replay indicator points at the
# wrong .skip-replay-<hash> sentinel. The legacy statusline used bare
# `md5`, which DOES NOT EXIST on Linux — the indicator was silently dead
# on every Linux host. Fix = a value-identical md5sum→md5→python3 helper
# `mp_proj_hash`. Locate the canonical statusline; SKIP if absent.
SL="$HOME/Resilio.Sync/Management/statusline-command.sh"
if [ -f "$SL" ]; then
  if grep -Eq 'md5 2>/dev/null \| head -c 8' "$SL"; then
    bad "statusline: legacy bare-md5 (Linux-dead) removed" "absent" "present"
  else ok "statusline: legacy bare-md5 (Linux-dead) removed"; fi
  if grep -q 'md5sum' "$SL"; then ok "statusline: derivation includes md5sum (Linux works)"
  else bad "statusline: derivation includes md5sum (Linux works)" "present" "absent"; fi
  FN="$(sed -n '/^mp_proj_hash() {/,/^}/p' "$SL")"
  if [ -n "$FN" ]; then
    sln=$(printf '%s' "$RK" | bash -c "$FN"'; mp_proj_hash')
    chk "statusline≡_mp_hash (native env, real key)" "61a15022" "$sln"
    sle=$(printf '' | bash -c "$FN"'; mp_proj_hash')
    chk "statusline≡_mp_hash md5('')" "d41d8cd9" "$sle"
    slw=$(printf '%s' "$RK" | bash -c "$HIDE_MD5 $FN"'; mp_proj_hash')
    chk "statusline≡_mp_hash (Windows/python3 profile)" "61a15022" "$slw"
  else
    bad "statusline: mp_proj_hash() helper present" "defined" "missing"
  fi
else
  echo "SKIP  statusline parity (no $SL on this host)"
fi

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fail FAILED"; exit 1; fi
