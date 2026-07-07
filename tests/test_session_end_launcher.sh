#!/bin/bash
# TDD: session-end.sh's detached replay launcher must be quote-safe and
# project-scoped in its error reporting.
#
# Bugs pinned:
#   1. The launcher built its `sh -c` body by STRING INTERPOLATION; a
#      project dir containing an apostrophe (basename lands inside a
#      single-quoted osascript arg) made the whole body a parse error —
#      no replay, no PID file, no error marker. Next session: "[No boot
#      context available]" — the silent-amnesia class, for any project
#      path with a quote in it. Fix: pass every dynamic value via env;
#      the body is a static single-quoted script.
#   2. stderr went to a FIXED /tmp/replay-error.log shared by every
#      project — concurrent replays clobbered each other and the synthetic
#      "Replay failed" boot context could embed the WRONG project's error.
#      Fix: per-project $SCRIPT_DIR/.replay-error-<hash>.log (covered by
#      the existing .replay-* gitignore/install excludes).
#   3. $BOOT_CTX.tmp was shared by concurrent same-project replays —
#      interleaved writes. Fix: unique .tmp.$$ suffix.
#
# Behavioral subprocess pattern: node + osascript stubbed via PATH.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HERE/../hooks"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT

# --- structural ------------------------------------------------------------
CODE="$(grep -v '^[[:space:]]*#' "$HOOKS/session-end.sh")"
if printf '%s\n' "$CODE" | grep -qF '/tmp/replay-error.log'; then
  bad "no fixed /tmp/replay-error.log in code" "shared cross-project error log still present"
else
  ok "no fixed /tmp/replay-error.log in code"
fi
if printf '%s\n' "$CODE" | grep -qF '.tmp.$$'; then
  ok "boot-context tmp file carries unique \$\$ suffix"
else
  bad "boot-context tmp file carries unique \$\$ suffix" "concurrent replays share one tmp path"
fi

# --- fixtures ----------------------------------------------------------------
ENGINE="$SBX/engine/hooks"
mkdir -p "$ENGINE"
cp "$HOOKS/session-end.sh" "$HOOKS/_lib.sh" "$ENGINE/"
chmod +x "$ENGINE/session-end.sh"
# shellcheck disable=SC1090
. "$HOOKS/_lib.sh"

# 6 real user turns → replay must launch.
T="$SBX/transcript.jsonl"
: > "$T"
i=1
while [ "$i" -le 6 ]; do
  printf '{"type":"user","message":{"role":"user","content":"q%s"}}\n' "$i" >> "$T"
  i=$((i + 1))
done

# Success stub: records argv, emits a valid boot context.
STUB_OK="$SBX/bin-ok"
mkdir -p "$STUB_OK"
cat > "$STUB_OK/node" <<EOF
#!/bin/sh
printf '%s\n' "\$2" >> "$SBX/ok-invocations"
echo "TITLE: stub replay ok"
echo "SUMMARY: from ok stub"
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUB_OK/osascript"
chmod +x "$STUB_OK/node" "$STUB_OK/osascript"

# Failure stub: stderr + exit 3.
STUB_FAIL="$SBX/bin-fail"
mkdir -p "$STUB_FAIL"
cat > "$STUB_FAIL/node" <<EOF
#!/bin/sh
echo "boom: stub replay exploded" >&2
exit 3
EOF
printf '#!/bin/sh\nexit 0\n' > "$STUB_FAIL/osascript"
chmod +x "$STUB_FAIL/node" "$STUB_FAIL/osascript"

# Benign stub: nothing to summarize (replay.mjs exit-2 contract).
STUB_BENIGN="$SBX/bin-benign"
mkdir -p "$STUB_BENIGN"
printf '#!/bin/sh\nexit 2\n' > "$STUB_BENIGN/node"
printf '#!/bin/sh\nexit 0\n' > "$STUB_BENIGN/osascript"
chmod +x "$STUB_BENIGN/node" "$STUB_BENIGN/osascript"

# --- case 1: apostrophe in the project path ---------------------------------
PROJ="$SBX/Nam's Proj.2026"
mkdir -p "$PROJ"
HASH=$(printf '%s' "$PROJ" | _mp_hash)
BC="$ENGINE/.boot-context-${HASH}"

printf '{"session_id":"sid-apos","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$T" "$PROJ" "$PROJ" \
  | PATH="$STUB_OK:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1

got=0
i=0
while [ "$i" -lt 8 ]; do
  [ -f "$BC" ] && { got=1; break; }
  sleep 0.5
  i=$((i + 1))
done
if [ "$got" -eq 1 ] && grep -q '^TITLE: stub replay ok' "$BC"; then
  ok "apostrophe project: replay launches and boot context lands"
else
  bad "apostrophe project: replay launches and boot context lands" \
      "bc=$(cat "$BC" 2>/dev/null | head -1) invocations=$(cat "$SBX/ok-invocations" 2>/dev/null)"
fi
grep -q '^sid-apos$' "$SBX/ok-invocations" 2>/dev/null \
  && ok "apostrophe project: replay received the session id intact" \
  || bad "apostrophe project: replay received the session id intact" \
         "invocations=$(cat "$SBX/ok-invocations" 2>/dev/null)"

# --- case 2: failure path writes per-project error log + synthetic banner ---
PROJ2="$SBX/Plain.Proj"
mkdir -p "$PROJ2"
HASH2=$(printf '%s' "$PROJ2" | _mp_hash)
BC2="$ENGINE/.boot-context-${HASH2}"
ERRLOG2="$ENGINE/.replay-error-${HASH2}.log"
ERRMARK2="$ENGINE/.replay-error-${HASH2}"

printf '{"session_id":"sid-boom","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$T" "$PROJ2" "$PROJ2" \
  | PATH="$STUB_FAIL:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1

got=0
i=0
while [ "$i" -lt 8 ]; do
  [ -f "$BC2" ] && { got=1; break; }
  sleep 0.5
  i=$((i + 1))
done
if [ "$got" -eq 1 ] && grep -q '^TITLE: Replay failed for prior session' "$BC2"; then
  ok "failure: synthetic error boot-context written"
else
  bad "failure: synthetic error boot-context written" "bc=$(cat "$BC2" 2>/dev/null | head -1)"
fi
grep -q 'boom: stub replay exploded' "$BC2" 2>/dev/null \
  && ok "failure: stderr tail embedded in synthetic SUMMARY" \
  || bad "failure: stderr tail embedded in synthetic SUMMARY" "bc=$(cat "$BC2" 2>/dev/null | tr '\n' ' | ')"
[ -f "$ERRLOG2" ] && grep -q 'boom: stub replay exploded' "$ERRLOG2" \
  && ok "failure: per-project .replay-error-<hash>.log holds stderr" \
  || bad "failure: per-project .replay-error-<hash>.log holds stderr" \
         "missing/empty: $ERRLOG2 — $(ls "$ENGINE" 2>/dev/null | tr '\n' ' ')"
[ -f "$ERRMARK2" ] && grep -q '^exit=3$' "$ERRMARK2" \
  && ok "failure: error marker records exit=3" \
  || bad "failure: error marker records exit=3" "got: $(cat "$ERRMARK2" 2>/dev/null)"

# --- case 3: error log is per-project (no cross-clobber) --------------------
# The apostrophe project's run must not have written PROJ2's error log path,
# and PROJ2's failure must not have touched PROJ1's (nonexistent) log.
[ ! -f "$ENGINE/.replay-error-${HASH}.log" ] \
  && ok "success run leaves no error log for its own project" \
  || bad "success run leaves no error log for its own project" "unexpected $(cat "$ENGINE/.replay-error-${HASH}.log" 2>/dev/null)"

# --- case 4: skip-replay sentinel — consumed, no replay, carry-forward ------
# The user opt-out path (boot-inject's "Skip-replay protocol"): a one-shot
# .skip-replay-<hash> must (a) suppress the replay launch even for a
# replay-worthy session, (b) be consumed (rm) so the NEXT session replays
# normally, (c) resurrect the prior boot context with the carry-forward
# header so the skip never breaks the memory chain
# (feedback_skip_replay_must_carry_forward).
PROJ3="$SBX/Skip.Proj"
mkdir -p "$PROJ3"
HASH3=$(printf '%s' "$PROJ3" | _mp_hash)
BC3="$ENGINE/.boot-context-${HASH3}"
SENT3="$ENGINE/.skip-replay-${HASH3}"
: > "$SENT3"
printf 'TITLE: pre-skip session\nSUMMARY: carried over the skip\n' > "$ENGINE/.boot-context-last-${HASH3}"

printf '{"session_id":"sid-skip","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$T" "$PROJ3" "$PROJ3" \
  | PATH="$STUB_OK:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1
sleep 1

[ ! -f "$SENT3" ] \
  && ok "skip sentinel: consumed (one-shot)" \
  || bad "skip sentinel: consumed (one-shot)" "sentinel still present"
grep -q '^sid-skip$' "$SBX/ok-invocations" 2>/dev/null \
  && bad "skip sentinel: replay NOT launched" "node stub was invoked" \
  || ok "skip sentinel: replay NOT launched"
if [ -f "$BC3" ] && grep -q '^\[Carry-forward: replay skipped by user request' "$BC3" \
   && grep -q 'TITLE: pre-skip session' "$BC3"; then
  ok "skip sentinel: prior boot context carried forward with skip header"
else
  bad "skip sentinel: prior boot context carried forward with skip header" \
      "bc=$(cat "$BC3" 2>/dev/null | head -2 | tr '\n' ' | ')"
fi

# --- case 5: exit-2 (benign no-op) must carry the prior context forward -----
# A LAUNCHED replay already passed the non-trivial gate; exiting 2 with no
# output (e.g. getSessionMessages empty) must not break the memory chain —
# same contract as the skip paths (feedback_skip_replay_must_carry_forward).
# The old branch deleted all evidence and wrote nothing: next session booted
# "[No boot context available]" silently.
PROJ5="$SBX/Benign.Proj"
mkdir -p "$PROJ5"
HASH5=$(printf '%s' "$PROJ5" | _mp_hash)
BC5="$ENGINE/.boot-context-${HASH5}"
printf 'TITLE: pre-benign session\nSUMMARY: carried over exit-2\n' > "$ENGINE/.boot-context-last-${HASH5}"

printf '{"session_id":"sid-benign","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$T" "$PROJ5" "$PROJ5" \
  | PATH="$STUB_BENIGN:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1
got=0; i=0
while [ "$i" -lt 8 ]; do
  [ -f "$BC5" ] && { got=1; break; }
  sleep 0.5; i=$((i + 1))
done
if [ "$got" -eq 1 ] && grep -q '^\[Carry-forward:' "$BC5" && grep -q 'TITLE: pre-benign session' "$BC5"; then
  ok "exit-2: prior boot context carried forward (benign no-op keeps the chain)"
else
  bad "exit-2: prior boot context carried forward (benign no-op keeps the chain)" \
      "bc=$(cat "$BC5" 2>/dev/null | head -2 | tr '\n' '|')"
fi
[ ! -f "$ENGINE/.replay-error-${HASH5}" ] \
  && ok "exit-2: no error marker (still benign, not a failure banner)" \
  || bad "exit-2: no error marker" "marker=$(cat "$ENGINE/.replay-error-${HASH5}" 2>/dev/null)"

# --- case 6: a fresh UNCONSUMED boot context at launch is preserved ----------
# If BOOT_CTX still exists at SessionEnd (concurrent same-project session's
# replay landed, or ours landed after the last prompt), it was never injected.
# The launch path used to rm it — a silently lost summary. It must be
# snapshotted to the carry-forward slot instead.
PROJ6="$SBX/Fresh.Proj"
mkdir -p "$PROJ6"
HASH6=$(printf '%s' "$PROJ6" | _mp_hash)
BC6="$ENGINE/.boot-context-${HASH6}"
LAST6="$ENGINE/.boot-context-last-${HASH6}"
printf 'TITLE: unconsumed fresh\nSUMMARY: never injected\n' > "$BC6"

printf '{"session_id":"sid-fresh","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"}}' \
    "$T" "$PROJ6" "$PROJ6" \
  | PATH="$STUB_OK:$PATH" bash "$ENGINE/session-end.sh" >/dev/null 2>&1
got=0; i=0
while [ "$i" -lt 8 ]; do
  grep -q '^TITLE: stub replay ok' "$BC6" 2>/dev/null && { got=1; break; }
  sleep 0.5; i=$((i + 1))
done
[ "$got" -eq 1 ] || bad "unconsumed: new replay still lands after preservation" "bc=$(cat "$BC6" 2>/dev/null | head -1)"
if [ -f "$LAST6" ] && grep -q 'TITLE: unconsumed fresh' "$LAST6"; then
  ok "unconsumed: fresh never-injected context snapshotted to -last- (not destroyed)"
else
  bad "unconsumed: fresh never-injected context snapshotted to -last- (not destroyed)" \
      "last=$(cat "$LAST6" 2>/dev/null | head -1)"
fi

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
