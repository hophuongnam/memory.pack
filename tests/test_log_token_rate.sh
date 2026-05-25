#!/bin/bash
# TDD: hooks/log-token-rate.sh — Stop hook that tails the transcript jsonl,
# extracts the most recent assistant .message.usage, and appends a cumulative-
# token sample to ~/.claude/statusline-token-rate.log. Race-tolerant: if no
# assistant entry is in the tail window (CC hasn't flushed yet), the hook
# exits 0 silently and writes NOTHING. The next Stop catches up.
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

# ─── multi-turn fixture: only the LAST assistant entry counts ─────────────
# CC's tail-n-50 looks at recent records; if multiple assistant turns are
# in the window, only the last cumulative count should be logged.
MULTI=$(mktemp); trap 'rm -rf "$SBX" "$MULTI"' EXIT
cat > "$MULTI" <<'JL'
{"type":"user","message":{"content":"q1"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"a1"}],"usage":{"input_tokens":10,"output_tokens":5}}}
{"type":"user","message":{"content":"q2"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"a2"}],"usage":{"input_tokens":100,"output_tokens":50}}}
JL
> "$LOG"
echo "{\"session_id\":\"sid-MULTI\",\"transcript_path\":\"$MULTI\",\"hook_event_name\":\"Stop\"}" | bash "$HOOK"
line=$(tail -n 1 "$LOG")
# Last assistant: 100 + 0 + 0 + 50 = 150
echo "$line" | grep -qE '^[0-9]+ sid-MULTI 150$' \
  && ok "multi-turn transcript: uses last assistant usage only" \
  || bad "multi-turn transcript: uses last assistant usage only" "got '$line'"

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
