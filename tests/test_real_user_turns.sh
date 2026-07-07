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
# auto-save-stop.sh behavioral (SMALL tool-heavy must NOT trigger; a big-raw
# file-READ session must NOT trigger while Bash-heavy AND Edit-heavy sessions DO
# — the size axis measures RELEVANT OUTPUT (conv + exec results + edit inputs),
# not raw bytes — MP_AUTOSAVE_MIN_CHARS, knob pinned both ways; a relevant-trip
# leaves the turn baseline untouched / independent "<turns> <relevant>"
# baselines keep the statusline countdown honest).

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

# --- layer 1c: _mp_relevant_output_chars unit ------------------------------
# The auto-save SIZE axis measures "relevant output" = conversation chars
# (extractConversation-equivalent) + the irreversible-work side of each tool:
# exec RESULTS (Bash / remote_run / remote_script tool_result bodies, joined via
# tool_use_id→name) + edit INPUTS (Edit/Write/MultiEdit/NotebookEdit tool_use
# input). It EXCLUDES Read/Grep/Glob results, attachments, thinking, and
# non-edit tool_use args — context the agent pulled in, not work it produced.
# Rationale is over-fire, not un-saved-bytes: the LIVE checkpoint feeds the live
# agent its full context; narrowing the axis just makes fire-rate track
# substance instead of context volume (the NexusLit "fires on prompt 1" case:
# 2.6MB raw, ~180k relevant). Expected total is hand-computed (jq tojson lengths
# verified: {"a":"bb"}=10):
#   10 (user string) + 5 (asst FIRST text; Bash tool_use ignored)
#   + 8 (Bash tool_result) + 10 (Write input {"a":"bb"}) + 0 (Read tool_use)
#   + 0 (Read result — not exec) + 0 (remote_run tool_use) + 3 (remote_run
#   result — exec) + 0 (isMeta) + 0 (orphan result) = 36
if ! type _mp_relevant_output_chars >/dev/null 2>&1; then
  bad "_lib.sh exports _mp_relevant_output_chars" "helper not defined"
else
  ok "_lib.sh exports _mp_relevant_output_chars"
fi

RELV="$SBX/relevant.jsonl"
cat > "$RELV" <<'JL'
{"type":"user","message":{"role":"user","content":"0123456789"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"ls"}},{"type":"text","text":"aaaaa"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b1","content":"BBBBBBBB"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"e1","name":"Write","input":{"a":"bb"}}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"r1","name":"Read","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"r1","content":"ZZZZZZ"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"rr1","name":"mcp__remote-shell__remote_run","input":{}}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"rr1","content":"RRR"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"qqqq"}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"orphan","content":"YYYY"}]}}
{"broken json
JL
got=$(_mp_relevant_output_chars "$RELV" 2>/dev/null)
[ "$got" = "36" ] \
  && ok "unit: relevant output = 36 (conv + Bash/remote results + edit input; Read/orphan/isMeta excluded)" \
  || bad "unit: relevant output = 36" "got '$got'"

got=$(_mp_relevant_output_chars "$SBX/does-not-exist.jsonl" 2>/dev/null)
[ "$got" = "0" ] && ok "unit: relevant output missing transcript → 0" || bad "unit: relevant output missing transcript → 0" "got '$got'"

got=$(_mp_relevant_output_chars "$SBX/empty.jsonl" 2>/dev/null)
[ "$got" = "0" ] && ok "unit: relevant output empty transcript → 0" || bad "unit: relevant output empty transcript → 0" "got '$got'"

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

# F) tilde transcript_path: CC may emit ~/-prefixed paths; auto-save-stop
#    expands them defensively, session-end must too — unexpanded, EVERY
#    session reads as 0 turns → trivial-skip forever → no replay, silently.
FH_TILDE="$SBX/fake-home-tilde"; mkdir -p "$FH_TILDE"
cp "$REAL" "$FH_TILDE/real-tilde.jsonl"
rm -f "$BC"
printf '{"session_id":"sid-tilde","transcript_path":"~/real-tilde.jsonl","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$PROJ" "$PROJ" \
  | HOME="$FH_TILDE" PATH="$STUB_BIN:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1
wait_for_launch "sid-tilde" \
  && ok "session-end: tilde transcript_path expands (6-turn session replays)" \
  || bad "session-end: tilde transcript_path expands (6-turn session replays)" "node stub never invoked"

# G) garbage knob env: MP_REPLAY_MIN_CHARS=abc must fall back to the default
#    (25000), not silently kill the rescue axis via a broken [ -ge ] test —
#    the conversation monster (~30k chars) must still replay.
rm -f "$BC"
printf '{"session_id":"sid-knob-garbage","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$CONV" "$PROJ" "$PROJ" \
  | MP_REPLAY_MIN_CHARS=abc PATH="$STUB_BIN:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1
wait_for_launch "sid-knob-garbage" \
  && ok "session-end: non-integer MP_REPLAY_MIN_CHARS falls back to default (axis alive)" \
  || bad "session-end: non-integer MP_REPLAY_MIN_CHARS falls back to default (axis alive)" "node stub never invoked"

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

# --- layer 3c: relevant-output SIZE axis (tool-heavy, few real turns) --------
# A turn-only gate never checkpoints a few-turn session that does heavy work.
# But RAW bytes over-measure: a session that only READS big files/attachments
# accrues megabytes of context that is NOT work, so a raw-byte axis fires on
# prompt 1 for pure context (the NexusLit case: 2.6MB raw, ~180k relevant). The
# size axis therefore measures RELEVANT OUTPUT (_mp_relevant_output_chars) =
# conversation + exec results (Bash/remote_run/remote_script) + edit inputs
# (Edit/Write/MultiEdit/NotebookEdit), tripping at MP_AUTOSAVE_MIN_CHARS
# (default 100000). Read/Grep results do NOT count; work-results + work-products
# do. (Narrowing the trigger fixes over-fire; the live checkpoint still feeds
# the agent its full context — this is not about what the detached replay saves.)
BIGRES=$(printf '%02000d' 0)   # 2000 chars; as a Write input {"content":...} → tojson 2014

# (1) THE FIX — big raw, but pure file-READS: must NOT trigger. 2 real turns +
# 130 Read pairs ×2000 → ~280KB raw (clears the OLD 200000 byte bar) but ~0
# relevant. A raw-byte axis triggers here (the bug); the relevant axis must not.
BIGREADY="$SBX/autosave-bigread.jsonl"
: > "$BIGREADY"
printf '{"type":"user","message":{"role":"user","content":"q1"}}\n' >> "$BIGREADY"
i=1
while [ "$i" -le 130 ]; do
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"r%s","name":"Read","input":{}}]}}\n' "$i" >> "$BIGREADY"
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"r%s","content":"%s"}]}}\n' "$i" "$BIGRES" >> "$BIGREADY"
  i=$((i + 1))
done
printf '{"type":"user","message":{"role":"user","content":"q2"}}\n' >> "$BIGREADY"
OUT=$(printf '{"session_id":"sid-bigread","stop_hook_active":false,"transcript_path":"%s"}' "$BIGREADY" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) bad "auto-save-stop: big-raw file-READ session does NOT trigger (relevant axis ignores Read results)" "blocked on context volume: $OUT" ;;
  *) ok "auto-save-stop: big-raw file-READ session does NOT trigger (relevant axis ignores Read results)" ;;
esac

# (2) Bash-heavy, few turns: exec RESULTS ≥ threshold → DOES trigger, even though
# raw (~130KB) is UNDER the old 200000 bar. 60 Bash pairs ×2000 = 120000 relevant.
BASHY="$SBX/autosave-bashy.jsonl"
: > "$BASHY"
printf '{"type":"user","message":{"role":"user","content":"q1"}}\n' >> "$BASHY"
i=1
while [ "$i" -le 60 ]; do
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b%s","name":"Bash","input":{}}]}}\n' "$i" >> "$BASHY"
  printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b%s","content":"%s"}]}}\n' "$i" "$BIGRES" >> "$BASHY"
  i=$((i + 1))
done
printf '{"type":"user","message":{"role":"user","content":"q2"}}\n' >> "$BASHY"
OUT=$(printf '{"session_id":"sid-bashy","stop_hook_active":false,"transcript_path":"%s"}' "$BASHY" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) ok "auto-save-stop: 2-turn Bash-heavy session triggers via relevant-output axis" ;;
  *) bad "auto-save-stop: 2-turn Bash-heavy session triggers via relevant-output axis" "no block: $OUT" ;;
esac

# (3) Edit-heavy, terse conv, few turns: work-PRODUCTS (edit inputs) ≥ threshold
# → DOES trigger. THE AMNESIA-GAP GUARD: an impl that counts exec results but
# NOT edit inputs scores this ~0 and skips it — silently losing edit-heavy
# autonomous work. 55 Write inputs ×2014 = 110770 relevant; raw ~116KB < old bar.
EDITY="$SBX/autosave-edity.jsonl"
: > "$EDITY"
printf '{"type":"user","message":{"role":"user","content":"q1"}}\n' >> "$EDITY"
i=1
while [ "$i" -le 55 ]; do
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"e%s","name":"Write","input":{"content":"%s"}}]}}\n' "$i" "$BIGRES" >> "$EDITY"
  i=$((i + 1))
done
printf '{"type":"user","message":{"role":"user","content":"q2"}}\n' >> "$EDITY"
OUT=$(printf '{"session_id":"sid-edity","stop_hook_active":false,"transcript_path":"%s"}' "$EDITY" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) ok "auto-save-stop: 2-turn Edit-heavy session triggers (edit inputs count as work)" ;;
  *) bad "auto-save-stop: 2-turn Edit-heavy session triggers (edit inputs count as work)" "no block: $OUT" ;;
esac

# (4) Independence pin: a relevant-axis trip must NOT advance the TURN baseline,
# or the statusline countdown resets to full on every size-save (turns climb
# slowly). Fresh session → turn baseline 0; after the BASHY trip the _last_save
# turn field stays 0 while the relevant field jumps to ≥100000. A coupled impl
# writes "2 <relevant>".
ls_turns=""; ls_rel=""
LSF="$HOME/.claude/hook_state/sid-bashy_last_save"
[ -f "$LSF" ] && read ls_turns ls_rel < "$LSF"
{ [ "$ls_turns" = "0" ] && [ "${ls_rel:-0}" -ge 100000 ]; } 2>/dev/null \
  && ok "auto-save-stop: relevant-trip leaves turn baseline untouched (independent baselines)" \
  || bad "auto-save-stop: relevant-trip leaves turn baseline untouched (independent baselines)" "_last_save='$ls_turns $ls_rel'"

# (5) Mutation guard (threshold UP): BASHY with the relevant bar maxed → axis
# can't fire and 2 turns is far below SAVE_INTERVAL → NO block. Pins
# MP_AUTOSAVE_MIN_CHARS as a real plumbed knob, not a hardcoded constant.
OUT=$(printf '{"session_id":"sid-bashy-hi","stop_hook_active":false,"transcript_path":"%s"}' "$BASHY" \
  | MP_AUTOSAVE_MIN_CHARS=999999999 bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) bad "auto-save-stop: raised MP_AUTOSAVE_MIN_CHARS disables relevant axis" "blocked: $OUT" ;;
  *) ok "auto-save-stop: raised MP_AUTOSAVE_MIN_CHARS disables relevant axis (2 turns, no turn trip)" ;;
esac

# (6) Mutation guard (threshold DOWN): the tiny HEAVY fixture (3 turns, conv
# "q1q2q3"=6 chars) clears a 1-char bar → blocks. Proves the knob plumbs down.
OUT=$(printf '{"session_id":"sid-heavy-lo","stop_hook_active":false,"transcript_path":"%s"}' "$HEAVY" \
  | MP_AUTOSAVE_MIN_CHARS=1 bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) ok "auto-save-stop: lowered MP_AUTOSAVE_MIN_CHARS rescues a small session" ;;
  *) bad "auto-save-stop: lowered MP_AUTOSAVE_MIN_CHARS rescues a small session" "no block: $OUT" ;;
esac

# (7) Garbage knob env: MP_AUTOSAVE_MIN_CHARS=100k must fall back to the
# default (100000), not silently disable the size axis via a broken [ -ge ]
# test — BASHY (120000 relevant) must still block.
OUT=$(printf '{"session_id":"sid-bashy-garbage","stop_hook_active":false,"transcript_path":"%s"}' "$BASHY" \
  | MP_AUTOSAVE_MIN_CHARS=100k bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT" in
  *'"decision"'*'"block"'*) ok "auto-save-stop: non-integer MP_AUTOSAVE_MIN_CHARS falls back to default (axis alive)" ;;
  *) bad "auto-save-stop: non-integer MP_AUTOSAVE_MIN_CHARS falls back to default (axis alive)" "no block: $OUT" ;;
esac

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
