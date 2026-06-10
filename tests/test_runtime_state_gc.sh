#!/bin/bash
# TDD: runtime state must not grow unboundedly. Before this existed:
#   * ~/.claude/hook_state/ held 759 per-session *_last_save files and a
#     478KB append-forever hook.log (auto-save-stop.sh, no GC)
#   * ~/.claude/statusline-token-rate.log appended one line per turn
#     forever; the statusline only ever reads the last 16 per session
#   * hooks/ held 216 .statusline-clock-* anchors from the removed
#     cache-age clock (one per session, never swept)
#
# Contracts pinned here:
#   1. auto-save-stop.sh prunes *_last_save older than 7 days (fresh kept)
#      and rotates hook.log past 512KB down to its newest 500 lines.
#   2. log-token-rate.sh rotates the token log past 4000 lines down to its
#      newest 2000 (newest entries preserved — the statusline tails them).
#   3. boot-inject.sh's SessionStart sweep removes legacy
#      .statusline-clock-* files (feature removed; sweep self-cleans any
#      host that ever ran the clock build).
# Rotation is tail+mv: a concurrent Stop's append can lose at worst one
# display sample — these are debug/display logs, never engine state.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HERE/../hooks"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT
export HOME="$SBX"
mkdir -p "$HOME/.claude/hook_state"
STATE_DIR="$HOME/.claude/hook_state"

# --- 1a. auto-save-stop: stale *_last_save pruned, fresh kept --------------
OLD="$STATE_DIR/oldsess_last_save"
FRESH="$STATE_DIR/freshsess_last_save"
echo 10 > "$OLD"
echo 20 > "$FRESH"
python3 -c "import os, time; t = time.time() - 8*86400; os.utime('$OLD', (t, t))"

printf '{"session_id":"sid-gc","stop_hook_active":false,"transcript_path":"/nonexistent.jsonl"}' \
  | bash "$HOOKS/auto-save-stop.sh" >/dev/null 2>&1

[ ! -f "$OLD" ] \
  && ok "auto-save GC: 8-day-old *_last_save pruned" \
  || bad "auto-save GC: 8-day-old *_last_save pruned" "still present"
[ -f "$FRESH" ] \
  && ok "auto-save GC: fresh *_last_save kept (mutation guard)" \
  || bad "auto-save GC: fresh *_last_save kept" "sweep deleted fresh state"

# --- 1b. auto-save-stop: hook.log rotated past 512KB -----------------------
LOG="$STATE_DIR/hook.log"
: > "$LOG"
i=0
while [ "$i" -lt 9000 ]; do
  printf 'old line %05d ----------------------------------------------------------\n' "$i"
  i=$((i + 1))
done >> "$LOG"
size_before=$(wc -c < "$LOG" | tr -d ' ')
[ "$size_before" -gt 524288 ] || bad "fixture: hook.log primed past 512KB" "size=$size_before"

printf '{"session_id":"sid-gc2","stop_hook_active":false,"transcript_path":"/nonexistent.jsonl"}' \
  | bash "$HOOKS/auto-save-stop.sh" >/dev/null 2>&1

lines_after=$(wc -l < "$LOG" | tr -d ' ')
[ "$lines_after" -le 502 ] \
  && ok "auto-save GC: hook.log rotated to newest 500 lines (got $lines_after)" \
  || bad "auto-save GC: hook.log rotated to newest 500 lines" "got $lines_after lines"
grep -q 'old line 08999' "$LOG" \
  && ok "auto-save GC: rotation keeps the NEWEST lines" \
  || bad "auto-save GC: rotation keeps the NEWEST lines" "tail entry missing after rotation"
grep -q 'sid-gc2' "$LOG" \
  && ok "auto-save GC: hook still logs after rotation" \
  || bad "auto-save GC: hook still logs after rotation" "no new entry"

# --- 2. log-token-rate: token log rotated past 4000 lines ------------------
TLOG="$HOME/.claude/statusline-token-rate.log"
: > "$TLOG"
i=0
while [ "$i" -lt 4500 ]; do
  printf '1700000000 sid-old %d\n' "$i"
  i=$((i + 1))
done >> "$TLOG"

printf '{"session_id":"sid-X","transcript_path":"%s","hook_event_name":"Stop"}' \
    "$HERE/fixtures/transcript-with-usage.jsonl" \
  | bash "$HOOKS/log-token-rate.sh" >/dev/null 2>&1

tlines=$(wc -l < "$TLOG" | tr -d ' ')
[ "$tlines" -le 2001 ] \
  && ok "token-rate GC: log rotated to ≤2000 lines (got $tlines)" \
  || bad "token-rate GC: log rotated to ≤2000 lines" "got $tlines"
grep -qE '^[0-9]+ sid-X 1559$' "$TLOG" \
  && ok "token-rate GC: this Stop's sample survives rotation" \
  || bad "token-rate GC: this Stop's sample survives rotation" "newest sample lost"
grep -q ' sid-old 4499$' "$TLOG" \
  && ok "token-rate GC: newest pre-existing lines survive" \
  || bad "token-rate GC: newest pre-existing lines survive" "tail of old log lost"
grep -q ' sid-old 10$' "$TLOG" \
  && bad "token-rate GC: oldest lines dropped" "head of old log still present" \
  || ok "token-rate GC: oldest lines dropped"

# Under the threshold: NO rotation (mutation guard — rotation must not
# truncate small logs).
: > "$TLOG"
printf '1700000000 sid-keep 1\n' >> "$TLOG"
printf '{"session_id":"sid-X","transcript_path":"%s","hook_event_name":"Stop"}' \
    "$HERE/fixtures/transcript-with-usage.jsonl" \
  | bash "$HOOKS/log-token-rate.sh" >/dev/null 2>&1
grep -q 'sid-keep' "$TLOG" \
  && ok "token-rate GC: small log untouched (mutation guard)" \
  || bad "token-rate GC: small log untouched" "small log was truncated"

# --- 3. boot-inject SessionStart sweeps legacy .statusline-clock-* ---------
ENGINE="$SBX/engine/hooks"
mkdir -p "$ENGINE"
cp "$HOOKS/boot-inject.sh" "$HOOKS/_lib.sh" "$ENGINE/"
chmod +x "$ENGINE/boot-inject.sh"
touch "$ENGINE/.statusline-clock-legacy-aaaa" "$ENGINE/.statusline-clock-legacy-bbbb"

printf '{"hook_event_name":"SessionStart","session_id":"sid-gc3","transcript_path":"","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$SBX" "$SBX" \
  | bash "$ENGINE/boot-inject.sh" >/dev/null 2>&1

if ls "$ENGINE"/.statusline-clock-* >/dev/null 2>&1; then
  bad "boot-inject sweep: legacy .statusline-clock-* removed at SessionStart" \
      "left: $(ls "$ENGINE"/.statusline-clock-* 2>/dev/null | tr '\n' ' ')"
else
  ok "boot-inject sweep: legacy .statusline-clock-* removed at SessionStart"
fi

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
