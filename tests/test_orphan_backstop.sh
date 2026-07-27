#!/bin/bash
# TDD: hooks/orphan-backstop.sh — the crash-orphan replay backstop.
#
# THE GAP (BUG-crash-orphan-amnesia): the detached replay is launched ONLY
# by session-end.sh on the SessionEnd hook, and CC's SessionEnd does not
# fire on abnormal termination (crash / force-quit / terminal closed / power
# loss). A crashed session's transcript is therefore never replayed: no
# boot context, no PENDING_MEMORIES mining — the next session boots blind
# about it. Auto-save checkpoints bound the loss mid-session, but the
# continuity thread itself is gone. Silent-amnesia class.
#
# THE FIX, two halves:
#   1. session-end.sh stamps ~/.claude/hook_state/<sid>_end_handled on EVERY
#      invocation (launch, trivial-skip, skip-sentinel alike) — a ledger of
#      "this session's end was handled".
#   2. orphan-backstop.sh (SessionStart) detaches a sweep that finds
#      post-baseline, in-horizon, QUIET (mtime), unstamped, non-current
#      transcripts across ALL ~/.claude/projects/*/, picks the newest per
#      project (a newer STAMPED sibling supersedes — replaying an older
#      orphan would REGRESS boot context), claims via noclobber stamp, and
#      pipes a synthesized SessionEnd stdin into the REAL session-end.sh —
#      which keeps every existing gate (trivial-skip, substance rescue,
#      resolver, carry-forward, detach) with zero duplication.
#
# LIVENESS IS QUIET-WINDOW, NOT lsof (verified against ground truth
# 2026-07-27): CC does NOT hold the transcript fd open between writes —
# lsof on a live session's own transcript exits 1 — so lsof can only serve
# as an opportunistic extra veto (if something DOES hold the file, skip),
# never as the primary "is it dead" signal. A quiet window fails SAFE: a
# live-but-silent session is merely swept later; a crashed one is quiet
# forever. Pass 2 (after the quiet window) catches the crash-then-
# immediate-restart case whose transcript is too fresh at SessionStart.
#
# cwd RESOLUTION MUST VERIFY (invariant #4): the orphan's project key is
# recovered from cwd values recorded INSIDE the transcript, resolved via
# _mp_resolve_project_key and accepted ONLY if the resolved key slugifies
# back to the transcript's parent-dir slug. No verified cwd → skip, never
# mis-file another project's boot context.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HERE/../hooks"
LIB="$HOOKS/_lib.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$HOOKS/orphan-backstop.sh" ] || { bad "hooks/orphan-backstop.sh exists" "missing"; echo "----"; echo "$fail FAILED"; exit 1; }
[ -f "$LIB" ] || { bad "hooks/_lib.sh exists" "missing"; echo "----"; echo "$fail FAILED"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

# --- helpers ----------------------------------------------------------------
# age <file> <seconds-ago>: set mtime relative to now (portable — BSD/GNU
# touch relative stamps differ; python3 is a hard engine dependency).
age() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"; }

# mk_transcript <path> <cwd> <n-real-turns>
mk_transcript() {
  _p="$1"; _c="$2"; _n="$3"
  mkdir -p "$(dirname "$_p")"
  : > "$_p"
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    printf '{"type":"user","cwd":"%s","message":{"content":"prompt %s and some padding text for substance"}}\n' "$_c" "$_i" >> "$_p"
    printf '{"type":"assistant","cwd":"%s","message":{"content":[{"type":"text","text":"reply %s"}]}}\n' "$_c" "$_i" >> "$_p"
    _i=$((_i+1))
  done
}

slugify() { printf '%s' "$1" | sed 's|[/.]|-|g'; }

# ---------------------------------------------------------------------------
# Layer A: session-end.sh stamps <sid>_end_handled on every handled path
# ---------------------------------------------------------------------------
SB_A="$TMP/sba/hooks"; mkdir -p "$SB_A"
cp "$HOOKS/session-end.sh" "$LIB" "$SB_A/"
chmod +x "$SB_A/session-end.sh"
BIN_A="$TMP/bin-a"; mkdir -p "$BIN_A"
printf '#!/bin/sh\nexit 2\n' > "$BIN_A/node"; chmod +x "$BIN_A/node"
FH_A="$TMP/home-a"; mkdir -p "$FH_A"

PROJ_A="$TMP/proj-a"; mkdir -p "$PROJ_A"
SLUG_A="$(slugify "$PROJ_A")"
HASH_A="$(printf '%s' "$PROJ_A" | _mp_hash)"

se_a() { # se_a <sid> <transcript> — run real session-end.sh sandboxed
  printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s"}' "$1" "$2" "$PROJ_A" \
    | HOME="$FH_A" PATH="$BIN_A:$PATH" bash "$SB_A/session-end.sh" >/dev/null 2>&1
}

# A1: launch path (6 real turns → past trivial gate) stamps
TR_A1="$FH_A/.claude/projects/$SLUG_A/sid-a1.jsonl"
mk_transcript "$TR_A1" "$PROJ_A" 6
se_a "sid-a1" "$TR_A1"
[ -f "$FH_A/.claude/hook_state/sid-a1_end_handled" ] \
  && ok "A1: launch path stamps <sid>_end_handled" \
  || bad "A1: launch path stamps <sid>_end_handled" "stamp missing"

# A2: trivial-skip path (1 tiny turn) stamps
TR_A2="$FH_A/.claude/projects/$SLUG_A/sid-a2.jsonl"
mk_transcript "$TR_A2" "$PROJ_A" 1
se_a "sid-a2" "$TR_A2"
[ -f "$FH_A/.claude/hook_state/sid-a2_end_handled" ] \
  && ok "A2: trivial-skip path stamps" \
  || bad "A2: trivial-skip path stamps" "stamp missing"

# A3: skip-replay sentinel path stamps (and still consumes the sentinel)
TR_A3="$FH_A/.claude/projects/$SLUG_A/sid-a3.jsonl"
mk_transcript "$TR_A3" "$PROJ_A" 6
: > "$SB_A/.skip-replay-$HASH_A"
se_a "sid-a3" "$TR_A3"
[ -f "$FH_A/.claude/hook_state/sid-a3_end_handled" ] \
  && ok "A3: skip-sentinel path stamps" \
  || bad "A3: skip-sentinel path stamps" "stamp missing"
[ ! -f "$SB_A/.skip-replay-$HASH_A" ] \
  && ok "A3: sentinel still consumed (existing contract intact)" \
  || bad "A3: sentinel still consumed" "sentinel left behind"

# ---------------------------------------------------------------------------
# Layer B: the sweep, with session-end.sh STUBBED (records synthesized stdin)
# ---------------------------------------------------------------------------
SB_B="$TMP/sbb/hooks"; mkdir -p "$SB_B"
cp "$HOOKS/orphan-backstop.sh" "$LIB" "$SB_B/"
chmod +x "$SB_B/orphan-backstop.sh"
REC="$TMP/rec"; mkdir -p "$REC"
cat > "$SB_B/session-end.sh" <<'STUB'
#!/bin/bash
cat > "$MP_TEST_REC/call.$$.$RANDOM"
exit 0
STUB
chmod +x "$SB_B/session-end.sh"

FH="$TMP/home-b"; mkdir -p "$FH/.claude/projects" "$FH/.claude/hook_state"
BASELINE="$FH/.claude/hook_state/orphan-baseline"

sweep() { # sweep [extra env assignments as VAR=VAL args]
  env HOME="$FH" MP_TEST_REC="$REC" MP_CURRENT_SID="sid-current" \
      MP_ORPHAN_PASS2=0 MP_ORPHAN_QUIET_MIN=30 "$@" \
      bash "$SB_B/orphan-backstop.sh" --sweep >/dev/null 2>&1
}
calls()      { ls "$REC" 2>/dev/null | wc -l | tr -d ' '; }
reset_rec()  { rm -f "$REC"/*; }
mk_orphan() { # mk_orphan <projdir> <sid> <age-seconds> [turns] → transcript path in $ORPHAN
  _proj="$1"; _sid="$2"; _age="$3"; _turns="${4:-3}"
  mkdir -p "$_proj"
  ORPHAN="$FH/.claude/projects/$(slugify "$_proj")/${_sid}.jsonl"
  mk_transcript "$ORPHAN" "$_proj" "$_turns"
  age "$ORPHAN" "$_age"
}

# B1: first run self-inits the baseline and touches nothing else
rm -f "$BASELINE"
mk_orphan "$TMP/proj-b1" "sid-b1" 2400
sweep
[ -f "$BASELINE" ] \
  && ok "B1: first sweep self-inits orphan-baseline" \
  || bad "B1: first sweep self-inits orphan-baseline" "baseline missing"
[ "$(calls)" = "0" ] \
  && ok "B1: pre-baseline transcripts exempt on init run" \
  || bad "B1: pre-baseline transcripts exempt on init run" "calls=$(calls)"
[ ! -f "$FH/.claude/hook_state/sid-b1_end_handled" ] \
  && ok "B1: init run claims nothing" \
  || bad "B1: init run claims nothing" "stamp appeared"

# All later cases: baseline far in the past
age "$BASELINE" 864000  # 10 days ago
rm -f "$FH/.claude/projects/$(slugify "$TMP/proj-b1")/sid-b1.jsonl"

# B2: happy path — quiet unstamped orphan → one synthesized SessionEnd
reset_rec
mk_orphan "$TMP/proj-b2" "sid-b2" 2400
sweep
[ "$(calls)" = "1" ] \
  && ok "B2: quiet unstamped orphan invokes session-end once" \
  || bad "B2: quiet unstamped orphan invokes session-end once" "calls=$(calls)"
CALL_FILE="$(ls "$REC"/call.* 2>/dev/null | head -1)"
if [ -n "$CALL_FILE" ]; then
  got_sid="$(jq -r '.session_id // empty' < "$CALL_FILE")"
  got_tr="$(jq -r '.transcript_path // empty' < "$CALL_FILE")"
  got_cwd="$(jq -r '.cwd // empty' < "$CALL_FILE")"
  got_ev="$(jq -r '.hook_event_name // empty' < "$CALL_FILE")"
  [ "$got_sid" = "sid-b2" ] && ok "B2: synthesized session_id" || bad "B2: synthesized session_id" "got=$got_sid"
  [ "$got_tr" = "$ORPHAN" ] && ok "B2: synthesized transcript_path" || bad "B2: synthesized transcript_path" "got=$got_tr"
  [ "$got_cwd" = "$TMP/proj-b2" ] && ok "B2: synthesized cwd (verified from transcript)" || bad "B2: synthesized cwd" "got=$got_cwd"
  [ "$got_ev" = "SessionEnd" ] && ok "B2: synthesized hook_event_name" || bad "B2: synthesized hook_event_name" "got=$got_ev"
else
  bad "B2: recorded call file present" "none"
fi
[ -f "$FH/.claude/hook_state/sid-b2_end_handled" ] \
  && ok "B2: claim stamp written" \
  || bad "B2: claim stamp written" "missing"

# B3: an already-stamped orphan is skipped
reset_rec
mk_orphan "$TMP/proj-b3" "sid-b3" 2400
: > "$FH/.claude/hook_state/sid-b3_end_handled"
sweep
[ "$(calls)" = "0" ] \
  && ok "B3: stamped orphan skipped" \
  || bad "B3: stamped orphan skipped" "calls=$(calls)"

# B4: a FRESH transcript (inside the quiet window) is not touched
reset_rec
mk_orphan "$TMP/proj-b4" "sid-b4" 10
sweep
[ "$(calls)" = "0" ] \
  && ok "B4: fresh (non-quiet) transcript skipped" \
  || bad "B4: fresh (non-quiet) transcript skipped" "calls=$(calls)"
[ ! -f "$FH/.claude/hook_state/sid-b4_end_handled" ] \
  && ok "B4: fresh transcript not claimed" \
  || bad "B4: fresh transcript not claimed" "stamp appeared"

# B5: the current session's own transcript is never swept
reset_rec
mk_orphan "$TMP/proj-b5" "sid-current" 2400
sweep
[ "$(calls)" = "0" ] \
  && ok "B5: current session excluded" \
  || bad "B5: current session excluded" "calls=$(calls)"

# B6: pre-baseline transcript exempt (baseline newer than transcript)
FH6="$TMP/home-b6"; mkdir -p "$FH6/.claude/hook_state"
: > "$FH6/.claude/hook_state/orphan-baseline"
age "$FH6/.claude/hook_state/orphan-baseline" 2000
_p6="$TMP/proj-b6"; mkdir -p "$_p6"
TR6="$FH6/.claude/projects/$(slugify "$_p6")/sid-b6.jsonl"
mk_transcript "$TR6" "$_p6" 3
age "$TR6" 4000   # older than the baseline
reset_rec
env HOME="$FH6" MP_TEST_REC="$REC" MP_CURRENT_SID="sid-current" \
    MP_ORPHAN_PASS2=0 MP_ORPHAN_QUIET_MIN=30 \
    bash "$SB_B/orphan-backstop.sh" --sweep >/dev/null 2>&1
[ "$(calls)" = "0" ] \
  && ok "B6: pre-baseline transcript exempt" \
  || bad "B6: pre-baseline transcript exempt" "calls=$(calls)"

# B7: a newer STAMPED sibling supersedes the orphan (regression guard)
reset_rec
mk_orphan "$TMP/proj-b7" "sid-b7-old" 3600
mk_orphan "$TMP/proj-b7" "sid-b7-done" 2400
: > "$FH/.claude/hook_state/sid-b7-done_end_handled"
sweep
[ "$(calls)" = "0" ] \
  && ok "B7: newer stamped sibling supersedes orphan" \
  || bad "B7: newer stamped sibling supersedes orphan" "calls=$(calls)"
[ ! -f "$FH/.claude/hook_state/sid-b7-old_end_handled" ] \
  && ok "B7: superseded orphan not claimed" \
  || bad "B7: superseded orphan not claimed" "stamp appeared"

# B8: two dead unstamped in one project → only the NEWEST replays
reset_rec
mk_orphan "$TMP/proj-b8" "sid-b8-older" 5400
mk_orphan "$TMP/proj-b8" "sid-b8-newer" 2400
sweep
[ "$(calls)" = "1" ] \
  && ok "B8: one candidate per project" \
  || bad "B8: one candidate per project" "calls=$(calls)"
CALL_FILE="$(ls "$REC"/call.* 2>/dev/null | head -1)"
got_sid="$(jq -r '.session_id // empty' < "${CALL_FILE:-/dev/null}" 2>/dev/null)"
[ "$got_sid" = "sid-b8-newer" ] \
  && ok "B8: newest orphan wins within a project" \
  || bad "B8: newest orphan wins within a project" "got=$got_sid"

# B9: cap MP_ORPHAN_MAX=1 across two projects → newest project wins
reset_rec
mk_orphan "$TMP/proj-b9x" "sid-b9x" 3000
mk_orphan "$TMP/proj-b9y" "sid-b9y" 2400
sweep MP_ORPHAN_MAX=1
[ "$(calls)" = "1" ] \
  && ok "B9: MP_ORPHAN_MAX caps launches per sweep" \
  || bad "B9: MP_ORPHAN_MAX caps launches per sweep" "calls=$(calls)"
CALL_FILE="$(ls "$REC"/call.* 2>/dev/null | head -1)"
got_sid="$(jq -r '.session_id // empty' < "${CALL_FILE:-/dev/null}" 2>/dev/null)"
[ "$got_sid" = "sid-b9y" ] \
  && ok "B9: newest-first ordering under the cap" \
  || bad "B9: newest-first ordering under the cap" "got=$got_sid"
rm -f "$FH/.claude/projects/$(slugify "$TMP/proj-b9x")/sid-b9x.jsonl"

# B10: transcript whose cwd never verifies against the slug → skip, no claim
reset_rec
_p10="$TMP/proj-b10"; mkdir -p "$_p10"
TR10="$FH/.claude/projects/$(slugify "$_p10")/sid-b10.jsonl"
mk_transcript "$TR10" "/somewhere/entirely-else" 3
age "$TR10" 2400
sweep
[ "$(calls)" = "0" ] \
  && ok "B10: unverifiable cwd → skipped (never mis-file)" \
  || bad "B10: unverifiable cwd → skipped" "calls=$(calls)"
[ ! -f "$FH/.claude/hook_state/sid-b10_end_handled" ] \
  && ok "B10: unverifiable cwd → not claimed" \
  || bad "B10: unverifiable cwd → not claimed" "stamp appeared"
rm -f "$TR10"

# B11: lsof veto — a file lsof reports open is skipped; exit-1 lsof proceeds
BIN_LSOF="$TMP/bin-lsof"; mkdir -p "$BIN_LSOF"
printf '#!/bin/sh\nexit 0\n' > "$BIN_LSOF/lsof"; chmod +x "$BIN_LSOF/lsof"
reset_rec
mk_orphan "$TMP/proj-b11" "sid-b11" 2400
env HOME="$FH" MP_TEST_REC="$REC" MP_CURRENT_SID="sid-current" \
    MP_ORPHAN_PASS2=0 MP_ORPHAN_QUIET_MIN=30 PATH="$BIN_LSOF:$PATH" \
    bash "$SB_B/orphan-backstop.sh" --sweep >/dev/null 2>&1
[ "$(calls)" = "0" ] \
  && ok "B11: lsof-open file vetoed" \
  || bad "B11: lsof-open file vetoed" "calls=$(calls)"
printf '#!/bin/sh\nexit 1\n' > "$BIN_LSOF/lsof"
env HOME="$FH" MP_TEST_REC="$REC" MP_CURRENT_SID="sid-current" \
    MP_ORPHAN_PASS2=0 MP_ORPHAN_QUIET_MIN=30 PATH="$BIN_LSOF:$PATH" \
    bash "$SB_B/orphan-backstop.sh" --sweep >/dev/null 2>&1
[ "$(calls)" = "1" ] \
  && ok "B11: lsof exit-1 (not open) proceeds (mutation pair)" \
  || bad "B11: lsof exit-1 proceeds" "calls=$(calls)"

# B12: project skip-replay sentinel → orphan skipped, sentinel NOT consumed
reset_rec
_p12="$TMP/proj-b12"
mk_orphan "$_p12" "sid-b12" 2400
HASH12="$(printf '%s' "$_p12" | _mp_hash)"
: > "$SB_B/.skip-replay-$HASH12"
sweep
[ "$(calls)" = "0" ] \
  && ok "B12: skip-replay sentinel blocks orphan replay" \
  || bad "B12: skip-replay sentinel blocks orphan replay" "calls=$(calls)"
[ -f "$SB_B/.skip-replay-$HASH12" ] \
  && ok "B12: sentinel left for the real session end (not consumed)" \
  || bad "B12: sentinel left for the real session end" "sentinel gone"
rm -f "$SB_B/.skip-replay-$HASH12" "$FH/.claude/projects/$(slugify "$_p12")/sid-b12.jsonl"

# B14: pass 2 re-scan is idempotent (claim makes it a no-op)
reset_rec
mk_orphan "$TMP/proj-b14" "sid-b14" 2400
sweep MP_ORPHAN_PASS2=1 MP_ORPHAN_PASS2_SLEEP=0
[ "$(calls)" = "1" ] \
  && ok "B14: two passes, one invocation (claim idempotence)" \
  || bad "B14: two passes, one invocation" "calls=$(calls)"

# B15: outside the horizon → skipped
reset_rec
mk_orphan "$TMP/proj-b15" "sid-b15" 432000   # 5 days
sweep
[ "$(calls)" = "0" ] \
  && ok "B15: beyond-horizon orphan skipped" \
  || bad "B15: beyond-horizon orphan skipped" "calls=$(calls)"

# ---------------------------------------------------------------------------
# Layer C: hook mode (stdin routing)
# ---------------------------------------------------------------------------
# C1: replay children never sweep (loop-breaker belt)
FH_C1="$TMP/home-c1"; mkdir -p "$FH_C1/.claude/hook_state"
printf '{"session_id":"sid-c1","source":"startup"}' \
  | env HOME="$FH_C1" MP_REPLAY_CHILD=1 MP_ORPHAN_SYNC=1 MP_TEST_REC="$REC" \
    bash "$SB_B/orphan-backstop.sh" >/dev/null 2>&1
rc=$?
[ "$rc" = "0" ] \
  && ok "C1: MP_REPLAY_CHILD exits 0" \
  || bad "C1: MP_REPLAY_CHILD exits 0" "rc=$rc"
[ ! -f "$FH_C1/.claude/hook_state/orphan-baseline" ] \
  && ok "C1: replay child never sweeps" \
  || bad "C1: replay child never sweeps" "baseline appeared"

# C2: source=resume → no sweep
FH_C2="$TMP/home-c2"; mkdir -p "$FH_C2/.claude/hook_state"
printf '{"session_id":"sid-c2","source":"resume"}' \
  | env HOME="$FH_C2" MP_ORPHAN_SYNC=1 MP_TEST_REC="$REC" \
    bash "$SB_B/orphan-backstop.sh" >/dev/null 2>&1
[ ! -f "$FH_C2/.claude/hook_state/orphan-baseline" ] \
  && ok "C2: source=resume does not sweep" \
  || bad "C2: source=resume does not sweep" "baseline appeared"

# C3: camelCase-only startup stdin sweeps (bilingual, invariant #3)
FH_C3="$TMP/home-c3"; mkdir -p "$FH_C3/.claude/hook_state"
printf '{"sessionId":"sid-c3","source":"startup"}' \
  | env HOME="$FH_C3" MP_ORPHAN_SYNC=1 MP_TEST_REC="$REC" \
    bash "$SB_B/orphan-backstop.sh" >/dev/null 2>&1
[ -f "$FH_C3/.claude/hook_state/orphan-baseline" ] \
  && ok "C3: camelCase-only stdin still sweeps (bilingual)" \
  || bad "C3: camelCase-only stdin still sweeps" "no baseline — sweep never ran"

# ---------------------------------------------------------------------------
# Layer D: structural pins
# ---------------------------------------------------------------------------
CODE_ONLY="$TMP/ob-code.sh"; grep -v '^[[:space:]]*#' "$HOOKS/orphan-backstop.sh" > "$CODE_ONLY"

# D1: the loop-breaker guard is code, not comment
grep -q 'MP_REPLAY_CHILD.*exit 0' "$CODE_ONLY" \
  && ok "D1: MP_REPLAY_CHILD guard is code" \
  || bad "D1: MP_REPLAY_CHILD guard is code" "guard missing from code lines"

# D2: wired in the canonical manifest (SessionStart)
jq -e '.entries[] | select(.event == "SessionStart" and .script == "orphan-backstop.sh")' \
   "$HERE/../install/hooks.manifest.json" >/dev/null 2>&1 \
  && ok "D2: manifest registers SessionStart orphan-backstop.sh" \
  || bad "D2: manifest registers SessionStart orphan-backstop.sh" "entry missing"

# D3: the claim is noclobber-atomic (set -C) — concurrent sweeps must not
# double-launch the same orphan
grep -q 'set -C' "$CODE_ONLY" \
  && ok "D3: noclobber claim present" \
  || bad "D3: noclobber claim present" "set -C not found in code lines"

# D4: the stamped-skip CANDIDATE filter is present. Structural, not
# behavioral, deliberately: dropping it is behaviorally equivalent (the
# noclobber claim rejects stamped sids anyway — mutation-verified
# 2026-07-27), but it is the cost guard that keeps handled transcripts from
# reaching the full-file jq cwd extraction on every sweep for the whole
# horizon window.
grep -q '_end_handled" \] && continue' "$CODE_ONLY" \
  && ok "D4: stamped-skip candidate filter present (cost guard)" \
  || bad "D4: stamped-skip candidate filter present" "filter deleted — every handled transcript pays the jq cwd pass"

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
