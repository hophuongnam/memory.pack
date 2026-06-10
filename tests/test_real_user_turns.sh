#!/bin/bash
# TDD: turn counters must count REAL user turns, not raw "type":"user"
# transcript entries. In real CC transcripts, tool_results come back as
# user-type entries and isMeta:true user entries are CC/engine bookkeeping
# (verified 2026-06-10: a 594-line transcript held 153 user-type entries
# but only 2 real prompts). Two counters were measuring entries:
#   session-end.sh  — "≤5 turns → skip replay" effectively never skipped
#                     (any session with ≥4 tool calls cleared the bar)
#   auto-save-stop.sh — "every 50 exchanges" fired after ~50 ENTRIES,
#                     i.e. a handful of real turns in tool-heavy sessions
#
# A REAL user turn = type=="user", NOT isMeta, content is a string without
# <command-message> (slash-command invocations are not exchanges) OR an
# array carrying no tool_result block. Mirrors log-token-rate.sh's
# mutation-pinned is_user_prompt (reference_cc_transcript_isMeta_mid_turn.md).
#
# Layers: 1) _lib.sh helper unit; 2) session-end.sh behavioral (trivial-skip
# + carry-forward vs replay launch, with node stubbed via PATH); 3)
# auto-save-stop.sh behavioral (tool-heavy session must NOT trigger).

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HERE/../hooks"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT

# --- layer 1: _mp_real_user_turns unit ------------------------------------
# shellcheck disable=SC1090
. "$HOOKS/_lib.sh" || { echo "FAIL  cannot source _lib.sh"; exit 1; }

if ! command -v _mp_real_user_turns >/dev/null 2>&1 && ! type _mp_real_user_turns >/dev/null 2>&1; then
  bad "_lib.sh exports _mp_real_user_turns" "helper not defined"
else
  ok "_lib.sh exports _mp_real_user_turns"
fi

MIX="$SBX/mixed.jsonl"
cat > "$MIX" <<'JL'
{"type":"user","message":{"role":"user","content":"real prompt 1"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"a"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"r"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"r"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"Stop hook feedback: AUTO-SAVE checkpoint reached"}}
{"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"}]}}
{"type":"user","message":{"role":"user","content":"real prompt 2"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"real prompt 3 (array form)"}]}}
{"type":"user","message":{"role":"user","content":"<command-message>foo</command-message><command-name>/foo</command-name>"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"r"},{"type":"text","text":"trailing"}]}}
JL
got=$(_mp_real_user_turns "$MIX" 2>/dev/null)
[ "$got" = "3" ] \
  && ok "unit: mixed transcript counts 3 real turns (tool_result/isMeta/command excluded)" \
  || bad "unit: mixed transcript counts 3 real turns" "got '$got'"

got=$(_mp_real_user_turns "$SBX/does-not-exist.jsonl" 2>/dev/null)
[ "$got" = "0" ] && ok "unit: missing transcript → 0" || bad "unit: missing transcript → 0" "got '$got'"

: > "$SBX/empty.jsonl"
got=$(_mp_real_user_turns "$SBX/empty.jsonl" 2>/dev/null)
[ "$got" = "0" ] && ok "unit: empty transcript → 0" || bad "unit: empty transcript → 0" "got '$got'"

printf '{"type":"user","message":{"content":"ok"}}\n{"broken json\n' > "$SBX/broken.jsonl"
got=$(_mp_real_user_turns "$SBX/broken.jsonl" 2>/dev/null)
[ "$got" = "1" ] && ok "unit: malformed line skipped, valid counted" || bad "unit: malformed line skipped, valid counted" "got '$got'"

# --- layer 2: session-end.sh behavioral -----------------------------------
ENGINE="$SBX/engine/hooks"
mkdir -p "$ENGINE"
cp "$HOOKS/session-end.sh" "$HOOKS/_lib.sh" "$ENGINE/"
chmod +x "$ENGINE/session-end.sh"

# Stub node + osascript via PATH: node records its invocation per session id
# and emits a valid boot context; osascript is silenced.
STUB_BIN="$SBX/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/node" <<EOF
#!/bin/sh
touch "$SBX/node-invoked-\$2"
echo "TITLE: stub replay"
echo "SUMMARY: from stub"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/osascript"
chmod +x "$STUB_BIN/node" "$STUB_BIN/osascript"

PROJ="$SBX/Fake.Proj"
mkdir -p "$PROJ"
PROJ_HASH=$(printf '%s' "$PROJ" | _mp_hash)

# Trivial-by-intent session: 2 real prompts buried in 20 tool_results.
TRIV="$SBX/trivial.jsonl"
: > "$TRIV"
printf '{"type":"user","message":{"role":"user","content":"q1"}}\n' >> "$TRIV"
i=1
while [ "$i" -le 20 ]; do
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t%s","content":"r"}]}}\n' "$i" >> "$TRIV"
  i=$((i + 1))
done
printf '{"type":"user","message":{"role":"user","content":"q2"}}\n' >> "$TRIV"

# Prior boot context to carry forward across the skip.
printf 'TITLE: prior session\nSUMMARY: carried\n' > "$ENGINE/.boot-context-last-${PROJ_HASH}"

printf '{"session_id":"sid-trivial","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$TRIV" "$PROJ" "$PROJ" \
  | PATH="$STUB_BIN:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1

sleep 1.5   # give a (wrongly) launched replay time to surface
if [ -f "$SBX/node-invoked-sid-trivial" ]; then
  bad "session-end: 2-real-turn session does NOT launch replay (20 tool_results ignored)" "replay was launched"
else
  ok "session-end: 2-real-turn session does NOT launch replay (20 tool_results ignored)"
fi
BC="$ENGINE/.boot-context-${PROJ_HASH}"
if [ -f "$BC" ] && grep -q '^\[Carry-forward: session had 2 user turn' "$BC"; then
  ok "session-end: trivial session carries prior boot context forward (count=2 in header)"
else
  bad "session-end: trivial session carries prior boot context forward (count=2 in header)" \
      "boot-ctx: $(cat "$BC" 2>/dev/null | head -2 | tr '\n' ' | ')"
fi

# Over-correction guard: 6 real prompts (+ tool noise) MUST still replay.
REAL="$SBX/real.jsonl"
: > "$REAL"
i=1
while [ "$i" -le 6 ]; do
  printf '{"type":"user","message":{"role":"user","content":"q%s"}}\n' "$i" >> "$REAL"
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t%s","content":"r"}]}}\n' "$i" >> "$REAL"
  i=$((i + 1))
done
rm -f "$BC"
printf '{"session_id":"sid-real","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$REAL" "$PROJ" "$PROJ" \
  | PATH="$STUB_BIN:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1

launched=0
i=0
while [ "$i" -lt 8 ]; do
  [ -f "$SBX/node-invoked-sid-real" ] && { launched=1; break; }
  sleep 0.5
  i=$((i + 1))
done
[ "$launched" -eq 1 ] \
  && ok "session-end: 6-real-turn session DOES launch replay (over-correction guard)" \
  || bad "session-end: 6-real-turn session DOES launch replay" "node stub never invoked"

# --- layer 3: auto-save-stop.sh behavioral --------------------------------
export HOME="$SBX/fake-home"
mkdir -p "$HOME/.claude"

# Tool-heavy session: 60 tool_results + 3 real prompts + 2 isMeta → 3 real
# turns → far below SAVE_INTERVAL → must NOT block.
HEAVY="$SBX/heavy.jsonl"
: > "$HEAVY"
i=1
while [ "$i" -le 60 ]; do
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t%s","content":"r"}]}}\n' "$i" >> "$HEAVY"
  i=$((i + 1))
done
printf '{"type":"user","message":{"role":"user","content":"q1"}}\n' >> "$HEAVY"
printf '{"type":"user","message":{"role":"user","content":"q2"}}\n' >> "$HEAVY"
printf '{"type":"user","message":{"role":"user","content":"q3"}}\n' >> "$HEAVY"
printf '{"type":"user","isMeta":true,"message":{"role":"user","content":"Stop hook feedback: x"}}\n' >> "$HEAVY"
printf '{"type":"user","isMeta":true,"message":{"role":"user","content":"<system-reminder>y</system-reminder>"}}\n' >> "$HEAVY"

OUT=$(printf '{"session_id":"sid-heavy","stop_hook_active":false,"transcript_path":"%s"}' "$HEAVY" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*)
    bad "auto-save-stop: tool-heavy session (3 real turns) does NOT trigger" "blocked: $OUT" ;;
  *) ok "auto-save-stop: tool-heavy session (3 real turns) does NOT trigger" ;;
esac

# Control: 51 REAL prompts still triggers (kept from drifting the other way).
MANY="$SBX/many.jsonl"
: > "$MANY"
i=1
while [ "$i" -le 51 ]; do
  printf '{"type":"user","message":{"role":"user","content":"q%s"}}\n' "$i" >> "$MANY"
  i=$((i + 1))
done
OUT=$(printf '{"session_id":"sid-many","stop_hook_active":false,"transcript_path":"%s"}' "$MANY" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) ok "auto-save-stop: 51 real turns still triggers (control)" ;;
  *) bad "auto-save-stop: 51 real turns still triggers (control)" "out=$OUT" ;;
esac

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
