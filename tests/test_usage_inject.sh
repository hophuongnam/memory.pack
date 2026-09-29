#!/bin/bash
# TDD: the quota gate on subagent launches.
#
#   statusline-command.sh  WRITES  <config>/hook_state/usage_windows
#   hooks/usage-inject.sh  READS it on PreToolUse(matcher Agent)
#
# Goal: the main agent must know the quota BEFORE it launches a subagent.
# PreToolUse fires after the model already decided to launch, so context alone
# arrives one launch too late — only a DENY stops the call, and its reason is
# what reaches the model. The gate therefore denies ONCE per session when the
# 5h window is ABOVE 90%, then lets the re-issued call through.
#
# 5h ONLY (user decision 2026-09-29): the hook ignores the 7d window and the
# statusline does not write it. The fixtures below still plant a 7d row — files written before this
# decision hold one, and the hook must not act on it.
#
# Cache format (mirrors usage_scoped — label LAST, stamp line first):
#     <write_epoch>
#     <pct> <resets_epoch> 5h
#
# The source is the statusline's stdin (documented `rate_limits`), not the
# OAuth endpoint: it re-renders on every CC event, so it is fresher than the
# 120s-TTL Stop worker. Real shapes were inspected before these fixtures were
# written (feedback_inspect_real_data_before_tdd_fixtures).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/usage-inject.sh"
SL="$HERE/../statusline-command.sh"
FIX="$HERE/fixtures/statusline-stdin-full.json"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[ -f "$HOOK" ] || { echo "FAIL  hooks/usage-inject.sh missing"; exit 1; }
[ -x "$HOOK" ] || bad "usage-inject.sh must have +x mode"

# $HOME sandbox BEFORE anything runs: both scripts write $HOME-relative state
# (feedback_tests_need_home_sandbox_for_state_paths).
SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT
export HOME="$SBX"
unset CLAUDE_CONFIG_DIR MP_REPLAY_CHILD
STATE="$HOME/.claude/hook_state"
WIN="$STATE/usage_windows"
mkdir -p "$STATE"

SH=sh; command -v dash >/dev/null 2>&1 && SH=dash
now() { date +%s; }
FUTURE=$(( $(now) + 4320 ))      # 1h 12m ahead
PAST=$(( $(now) - 60 ))

reset_sbx() { rm -f "$STATE"/* ; }
windows() { # <5h pct> <5h reset> <7d pct> <7d reset>
  printf '%s\n%s %s 5h\n%s %s 7d\n' "$(now)" "$1" "$2" "$3" "$4" > "$WIN"
}
stdin_for() { printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"prompt":"x"}}' "$1"; }
run() { stdin_for "${1:-sid-1}" | "$SH" "$HOOK" 2>"$SBX/err"; }

# ══════════════════════════════════════════════════════════════════════════
# LAYER 1 — the gate.
# ══════════════════════════════════════════════════════════════════════════

# G1 — 5h over the threshold → deny, reason names the window and the value.
reset_sbx; windows 93 "$FUTURE" 42 "$FUTURE"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && ok "over: exits 0" || bad "over: exits 0" "rc=$rc $(cat "$SBX/err")"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" = "PreToolUse" ] \
  && ok "over: hookEventName is PreToolUse" || bad "over: hookEventName is PreToolUse" "$out"
[ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = "deny" ] \
  && ok "over: permissionDecision is deny" || bad "over: permissionDecision is deny" "$out"
reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
case "$reason" in *"5h"*"93%"*) ok "over: reason carries the 5h value" ;;
                  *) bad "over: reason carries the 5h value" "$reason" ;; esac
case "$reason" in *"1h 1"[12]"m"*) ok "over: reason carries the time to reset" ;;
                  *) bad "over: reason carries the time to reset" "$reason" ;; esac
case "$reason" in *"7d"*) bad "over: the window under the threshold is NOT named" "$reason" ;;
                  *) ok "over: the window under the threshold is NOT named" ;; esac

# G2 — under → NO stdout at all (an empty JSON object would still be noise).
reset_sbx; windows 89 "$FUTURE" 42 "$FUTURE"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "under: silent, exit 0" || bad "under: silent, exit 0" "rc=$rc out=$out"

# G3 — the boundary is STRICT: "above 90%". 90 passes, 91 trips. Mutation pin
# for the operator, in both directions.
reset_sbx; windows 90 "$FUTURE" 42 "$FUTURE"
out=$(run)
[ -z "$out" ] && ok "boundary: exactly 90 does NOT trip" || bad "boundary: exactly 90 does NOT trip" "$out"
reset_sbx; windows 91 "$FUTURE" 42 "$FUTURE"
out=$(run)
[ -n "$out" ] && ok "boundary: 91 trips the gate" || bad "boundary: 91 trips the gate"

# G4 — the 7d window NEVER gates, however full.
reset_sbx; windows 10 "$FUTURE" 100 "$FUTURE"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "7d alone: never gates" || bad "7d alone: never gates" "$out"

# G5 — a window whose reset time has passed is stale BY DEFINITION: the value
# on disk belongs to the previous window. Usage only grows inside a window, so
# reset-in-the-future is the one staleness test this file needs.
reset_sbx; windows 99 "$PAST" 42 "$FUTURE"
out=$(run)
[ -z "$out" ] && ok "reset passed: the row is ignored" || bad "reset passed: the row is ignored" "$out"

# G6 — unknown reset (epoch 0) cannot be proven current → ignored. Fail OPEN:
# this hook BLOCKS a tool call, so every doubt resolves to "allow".
reset_sbx; windows 99 0 42 "$FUTURE"
out=$(run)
[ -z "$out" ] && ok "unknown reset: fail open" || bad "unknown reset: fail open" "$out"

# G7 — no cache → silent.
reset_sbx
out=$(run); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "no cache: silent, exit 0" || bad "no cache: silent, exit 0" "rc=$rc out=$out"

# G8 — torn cache under real dash: a non-integer operand in $(( )) or `[ -ge ]`
# is FATAL there (feedback_dash_arith_fatal_on_noninteger). Must stay silent,
# exit 0, and print nothing on stderr.
for body in "garbage" "$(now)\n9x $FUTURE 5h" "$(now)\n95 soon 5h" "$(now)\n95.5 $FUTURE 5h" "$(now)\n95" "$(now)\n95 $FUTURE Fable"; do
  reset_sbx; printf "$body\n" > "$WIN"
  out=$(run); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] && [ ! -s "$SBX/err" ] \
    && ok "torn cache '$(printf "$body" | tail -1)': silent, exit 0" \
    || bad "torn cache '$(printf "$body" | tail -1)': silent, exit 0" "rc=$rc out=$out err=$(cat "$SBX/err")"
done
# A torn STAMP must not hide a good row: the stamp only feeds the age text.
reset_sbx; printf 'not-a-stamp\n95 %s 5h\n' "$FUTURE" > "$WIN"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && [ -n "$out" ] && [ ! -s "$SBX/err" ] \
  && ok "torn stamp: the good row still trips" || bad "torn stamp: the good row still trips" "rc=$rc err=$(cat "$SBX/err")"

# ══════════════════════════════════════════════════════════════════════════
# LAYER 2 — deny ONCE. A gate that denies every call is a subagent kill switch.
# ══════════════════════════════════════════════════════════════════════════
MARK="$STATE/sid-1_quota_warned"

# O1 — first call denies and stamps the session marker.
reset_sbx; windows 93 "$FUTURE" 42 "$FUTURE"
out=$(run)
[ -n "$out" ] && [ -f "$MARK" ] && ok "once: first call denies + stamps the marker" \
                                || bad "once: first call denies + stamps the marker" "out=$out"

# O2 — a call inside the batch window (parallel Agent calls in ONE message)
# is denied too: their hooks run side by side, and letting the siblings
# through launches N-1 subagents the model never got to reconsider.
out=$(run)
[ -n "$out" ] && ok "once: a sibling call inside the batch window is denied" \
              || bad "once: a sibling call inside the batch window is denied"

# O3 — the re-issued call (marker older than the batch window) passes. THE
# assertion of this layer; mutation: drop the marker read and it goes red.
printf '%s\n' "$(( $(now) - 60 ))" > "$MARK"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "once: the re-issued call passes" \
                                 || bad "once: the re-issued call passes" "out=$out"

# O3b — the batch window must be SHORT. The deny reason promises "the next
# Agent call passes"; a model that re-issues the call 5s later must not be
# mistaken for a sibling of the denied batch (siblings land within ~1s).
printf '%s\n' "$(( $(now) - 5 ))" > "$MARK"
out=$(run)
[ -z "$out" ] && ok "once: a call re-issued after 5s passes" \
              || bad "once: a call re-issued after 5s passes" "the batch window is too wide"

# O4 — after an hour the warning re-arms (a long session can burn a lot more).
printf '%s\n' "$(( $(now) - 3700 ))" > "$MARK"
out=$(run)
[ -n "$out" ] && ok "once: re-arms after 1h" || bad "once: re-arms after 1h"
read -r m < "$MARK"
[ $(( $(now) - m )) -le 5 ] && ok "once: re-arm restamps the marker" || bad "once: re-arm restamps the marker" "got $m"

# O5 — the marker is per SESSION: another session gets its own warning.
reset_sbx; windows 93 "$FUTURE" 42 "$FUTURE"
printf '%s\n' "$(( $(now) - 60 ))" > "$MARK"
out=$(run sid-2)
[ -n "$out" ] && ok "once: a second session is warned on its own" || bad "once: a second session is warned on its own"

# O6 — torn marker under dash → treated as absent (deny + restamp), never fatal.
reset_sbx; windows 93 "$FUTURE" 42 "$FUTURE"
printf 'x.5\n' > "$MARK"
out=$(run); rc=$?
[ "$rc" -eq 0 ] && [ -n "$out" ] && [ ! -s "$SBX/err" ] \
  && ok "once: torn marker is not fatal" || bad "once: torn marker is not fatal" "rc=$rc err=$(cat "$SBX/err")"

# O7 — no session id → the once-only state cannot be kept, so FAIL OPEN.
# Denying here would deny every launch forever.
reset_sbx; windows 93 "$FUTURE" 42 "$FUTURE"
out=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Agent"}' | "$SH" "$HOOK" 2>/dev/null)
[ -z "$out" ] && ok "no session id: fail open" || bad "no session id: fail open" "$out"

# O8 — invariant #3: camelCase-only stdin still resolves the session.
reset_sbx; windows 93 "$FUTURE" 42 "$FUTURE"
out=$(printf '{"sessionId":"sid-camel","hookEventName":"PreToolUse"}' | "$SH" "$HOOK" 2>/dev/null)
[ -n "$out" ] && [ -f "$STATE/sid-camel_quota_warned" ] \
  && ok "camelCase stdin: session resolved" || bad "camelCase stdin: session resolved" "$out"

# O9 — a session id is external input that lands in a PATH. Anything that is
# not a plain id must fail open, never write outside hook_state.
reset_sbx; windows 93 "$FUTURE" 42 "$FUTURE"
out=$(printf '{"session_id":"../../escape"}' | "$SH" "$HOOK" 2>/dev/null)
[ -z "$out" ] && [ ! -e "$HOME/escape_quota_warned" ] && [ ! -e "$HOME/.claude/escape_quota_warned" ] \
  && ok "hostile session id: fail open, no write" || bad "hostile session id: fail open, no write" "$out"

# O10 — replay children never launch gated work; the belt (MP_REPLAY_CHILD).
reset_sbx; windows 93 "$FUTURE" 42 "$FUTURE"
out=$(stdin_for sid-1 | MP_REPLAY_CHILD=1 "$SH" "$HOOK" 2>/dev/null)
[ -z "$out" ] && [ ! -f "$MARK" ] && ok "replay child: no-op" || bad "replay child: no-op" "$out"
grep -v '^[[:space:]]*#' "$HOOK" | grep -q 'MP_REPLAY_CHILD.*exit 0' \
  && ok "MP_REPLAY_CHILD guard is code, not comment" || bad "MP_REPLAY_CHILD guard is code, not comment"

# ══════════════════════════════════════════════════════════════════════════
# LAYER 3 — per-account bucket. The windows belong to the account
# CLAUDE_CONFIG_DIR selects; the once-only marker indexes the SHARED session
# tree and stays on $HOME/.claude (project_multi_account_config_dir).
# ══════════════════════════════════════════════════════════════════════════
CFG="$SBX/.claude-work"
mkdir -p "$CFG/hook_state"

# A1 — the config-dir cache is the one that is read.
reset_sbx; rm -f "$CFG"/hook_state/*
printf '%s\n95 %s 5h\n' "$(now)" "$FUTURE" > "$CFG/hook_state/usage_windows"
out=$(stdin_for sid-1 | CLAUDE_CONFIG_DIR="$CFG/" "$SH" "$HOOK" 2>/dev/null)
[ -n "$out" ] && ok "cfg: reads \$CLAUDE_CONFIG_DIR/hook_state/usage_windows" \
              || bad "cfg: reads \$CLAUDE_CONFIG_DIR/hook_state/usage_windows"
[ -f "$MARK" ] && [ ! -f "$CFG/hook_state/sid-1_quota_warned" ] \
  && ok "cfg: the session marker stays on the shared hook_state" \
  || bad "cfg: the session marker stays on the shared hook_state"

# A2 — the OTHER account's cache must not gate this one.
reset_sbx; rm -f "$CFG"/hook_state/*
windows 99 "$FUTURE" 99 "$FUTURE"
out=$(stdin_for sid-1 | CLAUDE_CONFIG_DIR="$CFG" "$SH" "$HOOK" 2>/dev/null)
[ -z "$out" ] && ok "cfg: the shared cache does not gate a config-dir session" \
              || bad "cfg: the shared cache does not gate a config-dir session" "$out"

# ══════════════════════════════════════════════════════════════════════════
# LAYER 4 — the WRITER: the real statusline-command.sh.
# ══════════════════════════════════════════════════════════════════════════
render() { COLUMNS=200 MEMORY_PACK_NERDFONT=0 "$@" "$SL" 2>"$SBX/sl.err"; }

# S1 — fixture carries 58 / 31, both resetting at 9999999999.
reset_sbx
out=$(render "$SH" < "$FIX")
if [ -f "$WIN" ]; then
  { read -r s_stamp; read -r a_pct a_reset a_label; read -r b_pct b_reset b_label; } < "$WIN"
  d=$(( $(now) - s_stamp )); [ "$d" -lt 0 ] && d=$(( -d ))
  [ "$d" -le 5 ] && ok "writer: line 1 is the write epoch" || bad "writer: line 1 is the write epoch" "got '$s_stamp'"
  [ "$a_pct $a_reset $a_label" = "58 9999999999 5h" ] && ok "writer: 5h row" || bad "writer: 5h row" "got '$a_pct $a_reset $a_label'"
  [ -z "$b_pct$b_label" ] && ok "writer: no 7d row" || bad "writer: no 7d row" "got '$b_pct $b_reset $b_label'"
else
  bad "writer: statusline writes usage_windows" "no $WIN"
fi
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -ge 2 ] && ok "writer: the render still prints" || bad "writer: the render still prints" "$out"
extra=$(find "$STATE" -name 'usage_windows*' ! -name 'usage_windows' | wc -l | tr -d ' ')
[ "$extra" = "0" ] && ok "writer: no tmp litter" || bad "writer: no tmp litter" "$(find "$STATE" -name 'usage_windows*')"

# S2 — a fractional percentage lands as an INTEGER: the reader's int-guard
# would otherwise skip the row, and the gate would never trip.
reset_sbx
jq '.rate_limits.five_hour.used_percentage = 90.6' "$FIX" > "$SBX/float.json"
render "$SH" < "$SBX/float.json" >/dev/null
{ read -r _; read -r a_pct _ _; } < "$WIN" 2>/dev/null
[ "${a_pct:-}" = "91" ] && ok "writer: 90.6 lands as 91" || bad "writer: 90.6 lands as 91" "got '${a_pct:-}'"

# S3 — end to end: what the writer wrote, the gate reads.
reset_sbx
jq --argjson r "$FUTURE" '.rate_limits.five_hour = {used_percentage: 94, resets_at: $r}' "$FIX" > "$SBX/hot.json"
render "$SH" < "$SBX/hot.json" >/dev/null
reason=$(run | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)
case "$reason" in *"5h"*"94%"*) ok "end to end: statusline write → gate deny" ;;
                  *) bad "end to end: statusline write → gate deny" "$reason" ;; esac

# S4 — rate_limits absent (first render of a session) → last-good survives.
reset_sbx; windows 93 "$FUTURE" 42 "$FUTURE"; before=$(cat "$WIN")
jq 'del(.rate_limits)' "$FIX" > "$SBX/none.json"
render "$SH" < "$SBX/none.json" >/dev/null
[ "$(cat "$WIN")" = "$before" ] && ok "writer: no rate_limits → cache untouched" \
                                || bad "writer: no rate_limits → cache untouched" "$(cat "$WIN")"

# S5 — garbage values under dash: render NOT blanked. A garbage percentage
# writes no row; a garbage reset lands as the 0 sentinel.
reset_sbx
jq '.rate_limits.five_hour = {used_percentage: "1.2.3", resets_at: "soon"}' "$FIX" > "$SBX/bad.json"
out=$(render "$SH" < "$SBX/bad.json")
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -ge 2 ] && ok "writer: garbage does not blank the render" \
                                                       || bad "writer: garbage does not blank the render" "$out"
grep -q ' 5h$' "$WIN" 2>/dev/null && bad "writer: a garbage percentage writes no row" "$(cat "$WIN")" \
                                  || ok "writer: a garbage percentage writes no row"
reset_sbx
jq '.rate_limits.five_hour = {used_percentage: 95, resets_at: "soon"}' "$FIX" > "$SBX/bad2.json"
render "$SH" < "$SBX/bad2.json" >/dev/null
grep -q '^95 0 5h$' "$WIN" 2>/dev/null && ok "writer: a garbage reset lands as the 0 sentinel" \
                                       || bad "writer: a garbage reset lands as the 0 sentinel" "$(cat "$WIN" 2>/dev/null)"

# S5b — only the 7d window on stdin → nothing to write, last-good survives.
reset_sbx; windows 93 "$FUTURE" 42 "$FUTURE"; before=$(cat "$WIN")
jq 'del(.rate_limits.five_hour)' "$FIX" > "$SBX/only7d.json"
render "$SH" < "$SBX/only7d.json" >/dev/null
[ "$(cat "$WIN")" = "$before" ] && ok "writer: no 5h on stdin → cache untouched" \
                                || bad "writer: no 5h on stdin → cache untouched" "$(cat "$WIN")"

# S6 — the writer follows CLAUDE_CONFIG_DIR and leaves the shared cache alone.
reset_sbx; rm -f "$CFG"/hook_state/*
CLAUDE_CONFIG_DIR="$CFG" render "$SH" < "$FIX" >/dev/null
[ -f "$CFG/hook_state/usage_windows" ] && [ ! -f "$WIN" ] \
  && ok "writer: follows CLAUDE_CONFIG_DIR" || bad "writer: follows CLAUDE_CONFIG_DIR"

# ══════════════════════════════════════════════════════════════════════════
# LAYER 5 — wiring.
# ══════════════════════════════════════════════════════════════════════════
MAN="$HERE/../install/hooks.manifest.json"
jq -e '.entries[] | select(.event=="PreToolUse" and .matcher=="Agent" and .script=="usage-inject.sh")' \
   "$MAN" >/dev/null 2>&1 \
  && ok "manifest: PreToolUse/Agent → usage-inject.sh" || bad "manifest: PreToolUse/Agent → usage-inject.sh"
grep -q "_quota_warned" "$HERE/../hooks/auto-save-stop.sh" \
  && ok "GC: auto-save prunes *_quota_warned" || bad "GC: auto-save prunes *_quota_warned" "one marker per session leaks forever"

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
