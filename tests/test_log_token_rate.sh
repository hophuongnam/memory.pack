#!/bin/bash
# TDD: hooks/log-token-rate.sh — Stop hook that scans the transcript jsonl
# for per-turn cumulative-token samples and appends them to
# ~/.claude/statusline-token-rate.log. statusline-command.sh tails this log
# (last 16 per session) for the turn-rate sparkline.
#
# A "turn boundary" = an assistant entry with .message.usage whose immediate
# next user-or-assistant entry is a REAL user-prompt (string content, OR
# array content without tool_result blocks) — not a tool_result continuation,
# not an isMeta:true system-reminder injection (CC's own bookkeeping +
# Memory.Pack's auto-save-stop feedback both appear as isMeta:true user
# entries mid-turn; treating them as boundaries would emit spurious
# intermediate cumulatives). End-of-file also counts as a boundary.
#
# Backfill: on the first Stop of a /resume'd session, this catches up all
# prior turns' cumulatives so line-3 lights up from turn 1 instead of after
# the second Stop. Idempotent across re-fires via a monotonic cum > last-
# logged filter (cumulative-tokens are monotonic within a session by
# construction). Race-tolerant: if no usage info is in the transcript yet
# (CC hasn't flushed), exit 0 silently — next Stop catches up.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/log-token-rate.sh"
FIX="$HERE/fixtures"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[ -f "$HOOK" ] || { echo "FAIL  hooks/log-token-rate.sh missing"; exit 1; }
[ -x "$HOOK" ] || bad "hook must have +x mode"

# Sandbox a HOME so the hook writes to a temp log.
SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT
export HOME="$SBX"
mkdir -p "$HOME/.claude"
LOG="$HOME/.claude/statusline-token-rate.log"

# ─── happy path: assistant entry present, log line written ────────────────
TRANSCRIPT="$FIX/transcript-with-usage.jsonl"
echo "{\"session_id\":\"sid-X\",\"transcript_path\":\"$TRANSCRIPT\",\"hook_event_name\":\"Stop\"}" \
  | bash "$HOOK"
[ "$?" -eq 0 ] && ok "hook exits 0 on happy path" || bad "hook exits 0 on happy path"
[ -f "$LOG" ] && ok "log file created" || bad "log file created"

# Line format: "<epoch> sid-X <cum>", where cum = 42 + 1000 + 500 + 17 = 1559
line=$(tail -n 1 "$LOG" 2>/dev/null)
echo "$line" | grep -qE '^[0-9]+ sid-X 1559$' \
  && ok "log line format + cumulative tokens correct" \
  || bad "log line format + cumulative tokens correct" "got '$line'"

# ─── race-tolerant: no assistant entry → no log line written ──────────────
> "$LOG"  # truncate
echo "{\"session_id\":\"sid-Y\",\"transcript_path\":\"$FIX/transcript-no-assistant.jsonl\",\"hook_event_name\":\"Stop\"}" \
  | bash "$HOOK"
[ "$?" -eq 0 ] && ok "hook exits 0 on race-lost path" || bad "hook exits 0 on race-lost path"
[ ! -s "$LOG" ] && ok "race-lost: log NOT appended" || bad "race-lost: log NOT appended" "log non-empty"

# ─── empty transcript_path → exit 0, no write ─────────────────────────────
> "$LOG"
echo '{"session_id":"sid-Z","transcript_path":"","hook_event_name":"Stop"}' \
  | bash "$HOOK"
[ "$?" -eq 0 ] && ok "empty transcript_path → exit 0" || bad "empty transcript_path → exit 0"
[ ! -s "$LOG" ] && ok "empty transcript_path: log NOT appended" || bad "empty transcript_path: log NOT appended"

# ─── nonexistent transcript file → exit 0, no write ───────────────────────
> "$LOG"
echo '{"session_id":"sid-W","transcript_path":"/nonexistent/path.jsonl","hook_event_name":"Stop"}' \
  | bash "$HOOK"
[ "$?" -eq 0 ] && ok "missing transcript file → exit 0" || bad "missing transcript file → exit 0"
[ ! -s "$LOG" ] && ok "missing transcript file: log NOT appended" || bad "missing transcript file: log NOT appended"

# ─── camelCase stdin field names also accepted (invariant #3) ─────────────
> "$LOG"
echo "{\"sessionId\":\"sid-V\",\"transcriptPath\":\"$TRANSCRIPT\",\"hookEventName\":\"Stop\"}" \
  | bash "$HOOK"
line=$(tail -n 1 "$LOG" 2>/dev/null)
echo "$line" | grep -qE '^[0-9]+ sid-V 1559$' \
  && ok "camelCase stdin accepted" \
  || bad "camelCase stdin accepted" "got '$line'"

# ─── multi-turn fixture: backfill emits BOTH turn boundaries ──────────────
# Two completed turns, no tool_use, no isMeta. Backfill emits one log line
# per turn boundary (assistant whose next user-or-assistant is a user-prompt
# or EOF). Cumulative is monotonic so both 15 and 150 land.
MULTI=$(mktemp); trap 'rm -rf "$SBX" "$MULTI"' EXIT
cat > "$MULTI" <<'JL'
{"type":"user","message":{"content":"q1"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"a1"}],"usage":{"input_tokens":10,"output_tokens":5}}}
{"type":"user","message":{"content":"q2"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"a2"}],"usage":{"input_tokens":100,"output_tokens":50}}}
JL
> "$LOG"
echo "{\"session_id\":\"sid-MULTI\",\"transcript_path\":\"$MULTI\",\"hook_event_name\":\"Stop\"}" | bash "$HOOK"
n=$(grep -c '^[0-9]* sid-MULTI ' "$LOG")
[ "$n" -eq 2 ] && ok "multi-turn: both turn boundaries emitted (n=2)" || bad "multi-turn: both turn boundaries emitted" "got n=$n, log=$(cat "$LOG")"
grep -qE '^[0-9]+ sid-MULTI 15$'  "$LOG" && ok "multi-turn: turn 1 cum=15 logged"  || bad "multi-turn: turn 1 cum=15 logged"  "log=$(cat "$LOG")"
grep -qE '^[0-9]+ sid-MULTI 150$' "$LOG" && ok "multi-turn: turn 2 cum=150 logged" || bad "multi-turn: turn 2 cum=150 logged" "log=$(cat "$LOG")"

# ─── BACKFILL realism: tool_use loop + isMeta:true mid-turn injection ─────
# Shape verified against real CC transcripts on 2026-05-26. Critical cases:
#   • Multiple assistant entries within one turn (thinking, tool_use) —
#     only the LAST one before the next real user-prompt counts.
#   • A user-content entry whose .message.content is an array starting with
#     "tool_result" is a continuation, not a boundary.
#   • A user-content entry with .isMeta == true is CC bookkeeping
#     (system-reminder, our own auto-save-stop feedback) — must be skipped
#     in the boundary check, never treated as a real user-prompt.
BACKFILL=$(mktemp); trap 'rm -rf "$SBX" "$MULTI" "$BACKFILL"' EXIT
cat > "$BACKFILL" <<'JL'
{"type":"user","message":{"role":"user","content":"prompt 1"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"..."}],"usage":{"input_tokens":50,"output_tokens":20}}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"X","input":{}}],"usage":{"input_tokens":50,"output_tokens":25}}}
{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"r1"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"final 1"}],"usage":{"input_tokens":100,"output_tokens":50}}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"prompt 2"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"final 2"}],"usage":{"input_tokens":200,"output_tokens":100}}}
JL
> "$LOG"
echo "{\"session_id\":\"sid-BF\",\"transcript_path\":\"$BACKFILL\",\"hook_event_name\":\"Stop\"}" | bash "$HOOK"
[ "$?" -eq 0 ] && ok "backfill: hook exits 0" || bad "backfill: hook exits 0"
n=$(grep -c '^[0-9]* sid-BF ' "$LOG")
[ "$n" -eq 2 ] && ok "backfill: exactly 2 turn boundaries logged" || bad "backfill: exactly 2 turn boundaries logged" "got n=$n, log=$(cat "$LOG")"
# Turn 1: final assistant after tool_result + isMeta. cum = 100+0+0+50 = 150.
grep -qE '^[0-9]+ sid-BF 150$' "$LOG" && ok "backfill: turn 1 cum=150 (post-tool_use)" || bad "backfill: turn 1 cum=150" "log=$(cat "$LOG")"
# Turn 2: final assistant before EOF. cum = 200+0+0+100 = 300.
grep -qE '^[0-9]+ sid-BF 300$' "$LOG" && ok "backfill: turn 2 cum=300 (pre-EOF)" || bad "backfill: turn 2 cum=300" "log=$(cat "$LOG")"
# Intermediate cumulatives that MUST NOT appear:
#   thinking asst: 50+20 = 70 — followed by another assistant (not user)
#   tool_use asst: 50+25 = 75 — followed by user tool_result (not user-prompt)
for spurious in 70 75; do
  if grep -qE "^[0-9]+ sid-BF $spurious$" "$LOG"; then
    bad "backfill: intermediate cum=$spurious leaked (NOT a turn boundary)" "log=$(cat "$LOG")"
  else
    ok "backfill: intermediate cum=$spurious correctly skipped"
  fi
done

# ─── BACKFILL idempotency: 2nd fire on unchanged transcript adds nothing ──
n_before=$(wc -l < "$LOG")
echo "{\"session_id\":\"sid-BF\",\"transcript_path\":\"$BACKFILL\",\"hook_event_name\":\"Stop\"}" | bash "$HOOK"
n_after=$(wc -l < "$LOG")
[ "$n_before" -eq "$n_after" ] && ok "backfill: 2nd fire is no-op (idempotent)" || bad "backfill: 2nd fire idempotent" "before=$n_before after=$n_after"

# ─── BACKFILL monotonic filter: respects pre-existing log entries ─────────
# Prime log with turn 1's cum only; backfill must emit ONLY turn 2.
> "$LOG"
ts=$(date +%s)
printf '%s sid-BF 150\n' "$ts" > "$LOG"
echo "{\"session_id\":\"sid-BF\",\"transcript_path\":\"$BACKFILL\",\"hook_event_name\":\"Stop\"}" | bash "$HOOK"
n=$(grep -c '^[0-9]* sid-BF ' "$LOG")
[ "$n" -eq 2 ] && ok "backfill: monotonic filter — only cum>last_logged emitted" || bad "backfill: monotonic filter" "got n=$n log=$(cat "$LOG")"
grep -qE '^[0-9]+ sid-BF 300$' "$LOG" && ok "backfill: new turn cum=300 added" || bad "backfill: new turn cum=300 added"

# ─── BACKFILL session isolation: other sessions' entries are not double-counted ─
# Log has sid-BF 150; running for sid-OTHER must not see sid-BF's 150 as "last_cum".
> "$LOG"
printf '%s sid-OLD 999999\n' "$(date +%s)" > "$LOG"
echo "{\"session_id\":\"sid-BF\",\"transcript_path\":\"$BACKFILL\",\"hook_event_name\":\"Stop\"}" | bash "$HOOK"
n=$(grep -c '^[0-9]* sid-BF ' "$LOG")
[ "$n" -eq 2 ] && ok "backfill: per-session last_cum (sid-OLD's 999999 doesn't shadow sid-BF)" || bad "backfill: per-session last_cum" "got n=$n log=$(cat "$LOG")"

# ─── malformed JSONL line in tail → skipped silently ───────────────────────
# A truncated mid-write line from CC shouldn't crash the hook.
BAD=$(mktemp); trap 'rm -rf "$SBX" "$MULTI" "$BAD"' EXIT
cat > "$BAD" <<'JL'
{"type":"assistant","message":{"content":[{"type":"text","text":"a"}],"usage":{"input_tokens":7,"output_tokens":3}}}
{"type":"assistant","message":{"content":[{"type":"text","text":"b"}],"usage":{"input_tok
JL
> "$LOG"
echo "{\"session_id\":\"sid-BAD\",\"transcript_path\":\"$BAD\",\"hook_event_name\":\"Stop\"}" | bash "$HOOK"
[ "$?" -eq 0 ] && ok "malformed JSONL: hook exits 0" || bad "malformed JSONL: hook exits 0"
line=$(tail -n 1 "$LOG")
# Should fall back to the last VALID assistant entry: 7+0+0+3 = 10
echo "$line" | grep -qE '^[0-9]+ sid-BAD 10$' \
  && ok "malformed JSONL: uses last valid usage (10)" \
  || bad "malformed JSONL: uses last valid usage (10)" "got '$line'"

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
