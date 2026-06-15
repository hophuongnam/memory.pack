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
# Turn count alone is still a bad trivialness proxy in the other direction:
# a 1-2-prompt session can drive an hour of autonomous work (measured
# 2026-06-10: a real 2-turn session was 1.1MB raw with ~10k conversation
# chars; another 1-turn session held 49k conversation chars). session-end's
# skip gate therefore rescues ≤5-turn sessions that are big on EITHER axis:
# conversation chars (_mp_conversation_chars, mirrors extractConversation)
# ≥ MP_REPLAY_MIN_CHARS, or raw transcript bytes ≥ MP_REPLAY_MIN_BYTES.
# 0-turn sessions (headless/programmatic) always skip.
#
# Layers: 1) _lib.sh helper units (_mp_real_user_turns +
# _mp_conversation_chars); 2) session-end.sh behavioral (trivial-skip
# + carry-forward vs replay launch, with node stubbed via PATH, incl. the
# substance-rescue axes + knobs + 0-turn guard); 3)
# auto-save-stop.sh behavioral (SMALL tool-heavy must NOT trigger; LARGE
# tool-heavy DOES via the bytes axis — MP_AUTOSAVE_MIN_BYTES, knob pinned
# both ways; byte-trip leaves the turn baseline untouched / independent
# "<turns> <bytes>" baselines keep the statusline countdown honest).

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

# --- layer 1b: _mp_conversation_chars unit ---------------------------------
# Mirrors _lib.mjs extractConversation: non-isMeta user prompts (string, or
# tool_result-free array text joined with \n) + FIRST text block per
# assistant entry. Expected total below is hand-computed:
#   10 (user string) + 5 (assistant FIRST block only, not 15)
#   + 5 (assistant text after tool_use block) + 0 (isMeta) + 0 (tool_result)
#   + 5 ("dd"+\n+"ee") = 25, malformed line skipped.
if ! type _mp_conversation_chars >/dev/null 2>&1; then
  bad "_lib.sh exports _mp_conversation_chars" "helper not defined"
else
  ok "_lib.sh exports _mp_conversation_chars"
fi

SUBST="$SBX/subst.jsonl"
cat > "$SUBST" <<'JL'
{"type":"user","message":{"role":"user","content":"0123456789"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"aaaaa"},{"type":"text","text":"bbbbbbbbbb"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"X","input":{}},{"type":"text","text":"ccccc"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"ZZZZZZZZZZZZZZZZZZZZ"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ZZZZZZZZ"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"dd"},{"type":"text","text":"ee"}]}}
{"broken json
JL
got=$(_mp_conversation_chars "$SUBST" 2>/dev/null)
[ "$got" = "25" ] \
  && ok "unit: conversation chars = 25 (first-asst-block-only, isMeta/tool_result excluded, \\n join)" \
  || bad "unit: conversation chars = 25" "got '$got'"

got=$(_mp_conversation_chars "$SBX/does-not-exist.jsonl" 2>/dev/null)
[ "$got" = "0" ] && ok "unit: conversation chars missing transcript → 0" || bad "unit: conversation chars missing transcript → 0" "got '$got'"

got=$(_mp_conversation_chars "$SBX/empty.jsonl" 2>/dev/null)
[ "$got" = "0" ] && ok "unit: conversation chars empty transcript → 0" || bad "unit: conversation chars empty transcript → 0" "got '$got'"

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

# --- layer 2b: substance rescue (few turns, long session) -------------------
# wait_for_launch <sid> → 0 if the node stub fired for that session id
wait_for_launch() {
  _i=0
  while [ "$_i" -lt 8 ]; do
    [ -f "$SBX/node-invoked-$1" ] && return 0
    sleep 0.5
    _i=$((_i + 1))
  done
  return 1
}

# A) conversation-heavy: 2 real turns + 30 assistant texts ×1000 chars
#    → ~30k conversation chars ≥ MIN_CHARS default (25000) while raw stays
#    ~33KB < MIN_BYTES default (200000): the CHARS axis alone must rescue.
BIGTXT=$(printf '%01000d' 0)
CONV="$SBX/monster-conv.jsonl"
: > "$CONV"
printf '{"type":"user","message":{"role":"user","content":"q1"}}\n' >> "$CONV"
i=1
while [ "$i" -le 30 ]; do
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"%s"}]}}\n' "$BIGTXT" >> "$CONV"
  i=$((i + 1))
done
printf '{"type":"user","message":{"role":"user","content":"q2"}}\n' >> "$CONV"

rm -f "$BC"
printf '{"session_id":"sid-monster-conv","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$CONV" "$PROJ" "$PROJ" \
  | PATH="$STUB_BIN:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1
wait_for_launch "sid-monster-conv" \
  && ok "session-end: 2-turn session with ~30k conversation chars DOES replay (chars axis)" \
  || bad "session-end: 2-turn session with ~30k conversation chars DOES replay (chars axis)" "node stub never invoked"

# B) tool-heavy: 2 real turns + 120 tool_results ×2000 chars → raw ~250KB
#    ≥ MIN_BYTES while conversation is 4 chars < MIN_CHARS: the BYTES axis
#    alone must rescue (the measured real case: 2 turns, 1.1MB raw, ~10k
#    conversation chars — a chars-only gate skips it).
BIGRES=$(printf '%02000d' 0)
TOOLY="$SBX/monster-tools.jsonl"
: > "$TOOLY"
printf '{"type":"user","message":{"role":"user","content":"q1"}}\n' >> "$TOOLY"
i=1
while [ "$i" -le 120 ]; do
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t%s","content":"%s"}]}}\n' "$i" "$BIGRES" >> "$TOOLY"
  i=$((i + 1))
done
printf '{"type":"user","message":{"role":"user","content":"q2"}}\n' >> "$TOOLY"

sleep 0.5; rm -f "$BC"
printf '{"session_id":"sid-monster-tools","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$TOOLY" "$PROJ" "$PROJ" \
  | PATH="$STUB_BIN:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1
wait_for_launch "sid-monster-tools" \
  && ok "session-end: 2-turn session with ~250KB raw transcript DOES replay (bytes axis)" \
  || bad "session-end: 2-turn session with ~250KB raw transcript DOES replay (bytes axis)" "node stub never invoked"

# C) 0-turn guard: huge raw but ZERO real prompts (headless/programmatic
#    run) must still skip + carry forward — no human thread to carry.
ZERO="$SBX/zeroturn.jsonl"
: > "$ZERO"
i=1
while [ "$i" -le 120 ]; do
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t%s","content":"%s"}]}}\n' "$i" "$BIGRES" >> "$ZERO"
  i=$((i + 1))
done

sleep 0.5; rm -f "$BC"
printf '{"session_id":"sid-zeroturn","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$ZERO" "$PROJ" "$PROJ" \
  | PATH="$STUB_BIN:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1
sleep 1.5
if [ -f "$SBX/node-invoked-sid-zeroturn" ]; then
  bad "session-end: 0-turn huge session does NOT replay (headless guard)" "replay was launched"
elif [ -f "$BC" ] && grep -q '^\[Carry-forward: session had 0 user turn' "$BC"; then
  ok "session-end: 0-turn huge session does NOT replay (headless guard)"
else
  bad "session-end: 0-turn huge session does NOT replay (headless guard)" \
      "boot-ctx: $(head -1 "$BC" 2>/dev/null)"
fi

# D) knobs (raise): both thresholds maxed → even the conversation monster
#    skips + carries forward. Pins MP_REPLAY_MIN_CHARS/MP_REPLAY_MIN_BYTES
#    plumbing — a hardcoded gate passes A/B but fails here.
rm -f "$BC"
printf '{"session_id":"sid-knob-high","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$CONV" "$PROJ" "$PROJ" \
  | MP_REPLAY_MIN_CHARS=999999999 MP_REPLAY_MIN_BYTES=999999999 PATH="$STUB_BIN:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1
sleep 1.5
if [ -f "$SBX/node-invoked-sid-knob-high" ]; then
  bad "session-end: raised knobs re-skip the conversation monster" "replay was launched"
elif [ -f "$BC" ] && grep -q '^\[Carry-forward: session had 2 user turn' "$BC"; then
  ok "session-end: raised knobs re-skip the conversation monster"
else
  bad "session-end: raised knobs re-skip the conversation monster" \
      "boot-ctx: $(head -1 "$BC" 2>/dev/null)"
fi

# E) knobs (lower): tiny trivial transcript + MP_REPLAY_MIN_BYTES=1000 →
#    its ~2KB raw now clears the bar and must replay.
rm -f "$BC"
printf '{"session_id":"sid-knob-low","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$TRIV" "$PROJ" "$PROJ" \
  | MP_REPLAY_MIN_BYTES=1000 PATH="$STUB_BIN:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1
wait_for_launch "sid-knob-low" \
  && ok "session-end: lowered MP_REPLAY_MIN_BYTES rescues the trivial session" \
  || bad "session-end: lowered MP_REPLAY_MIN_BYTES rescues the trivial session" "node stub never invoked"

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

# Boundary: the block must fire at EXACTLY SAVE_INTERVAL real turns, not a
# turn early or late. These two assertions pin SAVE_INTERVAL=10 — they hold
# only for interval 10: at the old 50, ten real turns would not have blocked
# (the 3/51 cases above straddle any interval in 3..51 and never pinned it).
# A fresh session has no _last_save, so SINCE_LAST == the real-turn count.
EXACT="$SBX/boundary-exact.jsonl"
: > "$EXACT"
i=1
while [ "$i" -le 10 ]; do
  printf '{"type":"user","message":{"role":"user","content":"q%s"}}\n' "$i" >> "$EXACT"
  i=$((i + 1))
done
OUT=$(printf '{"session_id":"sid-bound-hit","stop_hook_active":false,"transcript_path":"%s"}' "$EXACT" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) ok "auto-save-stop: exactly 10 real turns triggers the block (SAVE_INTERVAL=10)" ;;
  *) bad "auto-save-stop: 10 real turns triggers the block (SAVE_INTERVAL=10)" "no block: $OUT" ;;
esac

UNDER="$SBX/boundary-under.jsonl"
: > "$UNDER"
i=1
while [ "$i" -le 9 ]; do
  printf '{"type":"user","message":{"role":"user","content":"q%s"}}\n' "$i" >> "$UNDER"
  i=$((i + 1))
done
OUT=$(printf '{"session_id":"sid-bound-miss","stop_hook_active":false,"transcript_path":"%s"}' "$UNDER" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) bad "auto-save-stop: 9 real turns must NOT trigger (one under SAVE_INTERVAL)" "blocked early: $OUT" ;;
  *) ok "auto-save-stop: 9 real turns does NOT trigger (one under SAVE_INTERVAL=10)" ;;
esac

# --- layer 3b: turn-countdown state cache (statusline line-1 indicator) -----
# auto-save-stop.sh already computes EXCHANGE_COUNT every Stop; it must ALSO
# cache "<since_last> <interval>" to ${sid}_turns so the statusline can render
# the turns-until-autosave countdown WITHOUT re-parsing the transcript (a
# second full-transcript jq pass per render would blow the statusline's
# ≤3-jq-fork budget). The sid-heavy / sid-many runs above already wrote these.
TF_HEAVY="$HOME/.claude/hook_state/sid-heavy_turns"
if [ -f "$TF_HEAVY" ]; then
  read th_since th_int < "$TF_HEAVY"
  [ "$th_since" = "3" ] && [ "$th_int" = "10" ] \
    && ok "auto-save-stop: caches '3 10' to \${sid}_turns (3 real turns, no prior save)" \
    || bad "auto-save-stop: caches '3 10' to \${sid}_turns" "got '$th_since $th_int'"
else
  bad "auto-save-stop: writes \${sid}_turns state file" "absent: $TF_HEAVY"
fi

# Trigger Stop still caches the SINCE_LAST that fired the block (51) — the
# statusline then shows 0 remaining (clamped) until the next turn resets it.
TF_MANY="$HOME/.claude/hook_state/sid-many_turns"
if [ -f "$TF_MANY" ]; then
  read tm_since tm_int < "$TF_MANY"
  [ "$tm_since" = "51" ] && [ "$tm_int" = "10" ] \
    && ok "auto-save-stop: trigger Stop caches '51 10' (the since-save that fired the block)" \
    || bad "auto-save-stop: trigger Stop caches '51 10'" "got '$tm_since $tm_int'"
else
  bad "auto-save-stop: trigger Stop writes \${sid}_turns" "absent: $TF_MANY"
fi

# 0-turn / unreadable-transcript Stop must NOT write a turns file: the
# statusline then stays clean (or keeps the last good value) rather than
# flickering to a full interval on a transient transcript-read race.
printf '{"session_id":"sid-zero-turns","stop_hook_active":false,"transcript_path":"%s/none.jsonl"}' "$SBX" \
  | bash "$HOOKS/auto-save-stop.sh" >/dev/null 2>&1
[ ! -f "$HOME/.claude/hook_state/sid-zero-turns_turns" ] \
  && ok "auto-save-stop: 0-turn Stop writes NO turns file (clean / last-good)" \
  || bad "auto-save-stop: 0-turn Stop writes NO turns file" "file created on a 0-turn Stop"

# --- layer 3c: transcript-SIZE axis (tool-heavy, few real turns) ------------
# A turn-only gate never checkpoints a tool-heavy session: measured 2026-06-13,
# a real 2MB transcript held only 2 real turns and ~14k conversation chars
# (below the 25k chars floor too) — tool work shows up in BYTES, nothing else.
# At SAVE_INTERVAL=10 such a session ends without a single auto-save → silent
# amnesia, the engine's core failure mode. auto-save-stop must therefore ALSO
# trip when bytes-since-save ≥ MP_AUTOSAVE_MIN_BYTES (default 200000). Mirrors
# session-end's bytes-axis rescue (layer 2b/B).
BIGRES=$(printf '%02000d' 0)
TOOLY="$SBX/autosave-tooly.jsonl"
: > "$TOOLY"
printf '{"type":"user","message":{"role":"user","content":"q1"}}\n' >> "$TOOLY"
i=1
while [ "$i" -le 120 ]; do
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t%s","content":"%s"}]}}\n' "$i" "$BIGRES" >> "$TOOLY"
  i=$((i + 1))
done
printf '{"type":"user","message":{"role":"user","content":"q2"}}\n' >> "$TOOLY"   # ~250KB raw, 2 real turns

OUT=$(printf '{"session_id":"sid-tooly","stop_hook_active":false,"transcript_path":"%s"}' "$TOOLY" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) ok "auto-save-stop: 2-turn ~250KB session triggers via bytes axis" ;;
  *) bad "auto-save-stop: 2-turn ~250KB session triggers via bytes axis" "no block: $OUT" ;;
esac

# Independence pin: a byte-only trip must NOT advance the TURN baseline, or the
# statusline countdown resets to full on every size-save in tool-heavy sessions
# (turns climb slowly) — it would sit near-full while saves fire "out of
# nowhere". Fresh session → turn baseline 0; after a byte trip the _last_save
# turn field stays 0 while the byte field jumps to the transcript size. A
# coupled impl would write "2 <bytes>" here.
ls_turns=""; ls_bytes=""
LSF="$HOME/.claude/hook_state/sid-tooly_last_save"
[ -f "$LSF" ] && read ls_turns ls_bytes < "$LSF"
{ [ "$ls_turns" = "0" ] && [ "${ls_bytes:-0}" -ge 200000 ]; } 2>/dev/null \
  && ok "auto-save-stop: byte-trip leaves turn baseline untouched (independent baselines)" \
  || bad "auto-save-stop: byte-trip leaves turn baseline untouched (independent baselines)" "_last_save='$ls_turns $ls_bytes'"

# Mutation guard (threshold UP): same 2-turn fixture with the byte bar maxed →
# byte axis can't fire and 2 turns is far below SAVE_INTERVAL → NO block. Flips
# on the byte axis ALONE (a ≥10-turn fixture would block for the wrong reason).
# Pins MP_AUTOSAVE_MIN_BYTES as a real plumbed knob, not a hardcoded constant.
OUT=$(printf '{"session_id":"sid-tooly-hi","stop_hook_active":false,"transcript_path":"%s"}' "$TOOLY" \
  | MP_AUTOSAVE_MIN_BYTES=999999999 bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) bad "auto-save-stop: raised MP_AUTOSAVE_MIN_BYTES disables byte axis" "blocked: $OUT" ;;
  *) ok "auto-save-stop: raised MP_AUTOSAVE_MIN_BYTES disables byte axis (2 turns, no turn trip)" ;;
esac

# Mutation guard (threshold DOWN): the tiny ~5KB HEAVY fixture (3 turns) clears
# a 1000-byte bar → blocks. Proves the knob plumbs downward too.
OUT=$(printf '{"session_id":"sid-heavy-lo","stop_hook_active":false,"transcript_path":"%s"}' "$HEAVY" \
  | MP_AUTOSAVE_MIN_BYTES=1000 bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) ok "auto-save-stop: lowered MP_AUTOSAVE_MIN_BYTES rescues a small session" ;;
  *) bad "auto-save-stop: lowered MP_AUTOSAVE_MIN_BYTES rescues a small session" "no block: $OUT" ;;
esac

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
