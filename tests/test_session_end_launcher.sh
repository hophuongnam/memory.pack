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

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
