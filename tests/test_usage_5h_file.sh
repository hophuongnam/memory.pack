#!/bin/bash
# TDD: the statusline writes the 5h window percentage to ONE file in /tmp.
#
#   statusline-command.sh  WRITES  /tmp/claude-usage-5h   ("94\n", one line)
#
# User decision 2026-09-29: the PreToolUse quota gate (hooks/usage-inject.sh)
# did not work and is removed. Only the number stays, for anything to read.
# MP_USAGE_5H_FILE overrides the path so this suite never touches the real one.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SL="$HERE/../statusline-command.sh"
FIX="$HERE/fixtures/statusline-stdin-full.json"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT
export HOME="$SBX"
unset CLAUDE_CONFIG_DIR
export MP_USAGE_5H_FILE="$SBX/out/claude-usage-5h"
F="$MP_USAGE_5H_FILE"
mkdir -p "$SBX/out"

SH=sh; command -v dash >/dev/null 2>&1 && SH=dash
render() { COLUMNS=200 MEMORY_PACK_NERDFONT=0 "$SH" "$SL" 2>"$SBX/sl.err"; }
reset_sbx() { rm -f "$SBX"/out/*; }

# W1 — fixture carries 58 on the 5h window: the file is exactly "58\n".
reset_sbx
out=$(render < "$FIX")
[ "$(cat "$F" 2>/dev/null)" = "58" ] && [ "$(wc -l < "$F" | tr -d ' ')" = "1" ] \
  && ok "writer: one line, the 5h percentage" || bad "writer: one line, the 5h percentage" "$(cat "$F" 2>/dev/null)"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -ge 2 ] && ok "writer: the render still prints" || bad "writer: the render still prints" "$out"
[ "$(ls "$SBX/out")" = "claude-usage-5h" ] && ok "writer: no tmp litter" || bad "writer: no tmp litter" "$(ls "$SBX/out")"

# W2 — a fractional percentage lands as an INTEGER.
reset_sbx
jq '.rate_limits.five_hour.used_percentage = 90.6' "$FIX" > "$SBX/float.json"
render < "$SBX/float.json" >/dev/null
[ "$(cat "$F" 2>/dev/null)" = "91" ] && ok "writer: 90.6 lands as 91" || bad "writer: 90.6 lands as 91" "$(cat "$F" 2>/dev/null)"

# W3 — no rate_limits (first render of a session) or no 5h → last-good kept.
for case_ in 'del(.rate_limits)' 'del(.rate_limits.five_hour)'; do
  reset_sbx; echo 93 > "$F"
  jq "$case_" "$FIX" > "$SBX/none.json"
  render < "$SBX/none.json" >/dev/null
  [ "$(cat "$F")" = "93" ] && ok "writer: $case_ → file untouched" || bad "writer: $case_ → file untouched" "$(cat "$F")"
done

# W4 — garbage under dash: render NOT blanked, last-good kept.
reset_sbx; echo 93 > "$F"
jq '.rate_limits.five_hour.used_percentage = "1.2.3"' "$FIX" > "$SBX/bad.json"
out=$(render < "$SBX/bad.json")
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -ge 2 ] && ok "writer: garbage does not blank the render" || bad "writer: garbage does not blank the render" "$out"
[ "$(cat "$F")" = "93" ] && ok "writer: garbage writes nothing" || bad "writer: garbage writes nothing" "$(cat "$F")"

# W5 — the default path is /tmp/claude-usage-5h; the old per-account file is gone.
grep -q 'MP_USAGE_5H_FILE:-/tmp/claude-usage-5h' "$SL" \
  && ok "default path is /tmp/claude-usage-5h" || bad "default path is /tmp/claude-usage-5h"
grep -q 'usage_windows' "$SL" && bad "statusline no longer writes usage_windows" || ok "statusline no longer writes usage_windows"

# W6 — the quota gate hook is gone: script, manifest entry.
[ ! -e "$HERE/../hooks/usage-inject.sh" ] && ok "hooks/usage-inject.sh removed" || bad "hooks/usage-inject.sh removed"
grep -q 'usage-inject' "$HERE/../install/hooks.manifest.json" \
  && bad "manifest has no usage-inject entry" || ok "manifest has no usage-inject entry"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "$fail FAILED"
exit $((fail > 0))
