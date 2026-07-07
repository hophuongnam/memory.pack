#!/bin/bash
# TDD: hooks/boot-catchup.sh is the PostToolUse "catch-up" injector that
# closes the mid-turn boot-context gap (BUG-boot-context-mid-turn-gap).
#
# The gap: boot context is injected only on SessionStart (polls 4s) and
# UserPromptSubmit (polls 9s). When the prior session's detached replay
# takes longer than both windows, the first (long) turn runs blind: the
# `.boot-context-<hash>` file lands on disk mid-turn but nothing injects it
# until the NEXT user prompt. PostToolUse fires between tool calls, so a
# matcher-less PostToolUse hook catches the file the moment it appears.
#
# CAPABILITY VERIFIED AGAINST GROUND TRUTH (not docs): CC bundle 2.1.181
# constructs a {type:"hook_additional_context", hookEvent:"PostToolUse", …}
# message from a PostToolUse hook's additionalContext, keyed to the tool's
# toolUseID — injected into the model on its next request within the SAME
# turn. See reference_cc_posttooluse_additionalcontext.
#
# THE SHARED-DIR HAZARD (this is what makes the gate non-trivial): hooks are
# wired by ABSOLUTE path to ONE shared hooks/ dir, and EVERY project writes
# its .boot-context-<hash> there. A matcher-less PostToolUse hook fires in
# every project's session, so it MUST act only on THIS session's own hash —
# resolved from stdin's transcript_path. Acting on another project's
# unconsumed leftover makes boot-inject (which resolves OUR hash, finds no
# file) emit "[No boot context available]" AND flip our .boot-marker-<sid>
# to "none" on EVERY tool call for the whole window the foreign file sits
# there. Case D + the Layer-2 foreign-marker case pin this regression.
#
# Two layers mirror the project's accepted patterns:
#   Layer 1 — subprocess with a STUB boot-inject (echoes EXEC_BI): isolates
#             the gate's routing decision with REAL hash resolution.
#   Layer 2 — subprocess with the REAL boot-inject: proves the PostToolUse
#             event flows end-to-end to an emitted additionalContext + the
#             carry-forward mv, and that a foreign-only dir corrupts nothing.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HERE/../hooks"
LIB="$HOOKS/_lib.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$HOOKS/boot-catchup.sh" ] || { bad "hooks/boot-catchup.sh exists" "missing"; echo "----"; echo "$fail FAILED"; exit 1; }
[ -f "$LIB" ]                   || { bad "hooks/_lib.sh exists" "missing";          echo "----"; echo "$fail FAILED"; exit 1; }

# shellcheck disable=SC1090
. "$LIB"

# --- structural: forkless fast-reject must precede any cat/jq/_lib ----------
# A clean dir (no live context anywhere) must exit without reading stdin or
# forking. The .boot-context-* glob loop must therefore come before the first
# $(cat / jq / _lib.sh source in the script body.
# (strip comment lines first — test_statusline_marker_path.sh:45 idiom — so a
# comment mentioning jq/_lib can't satisfy the "fork" match.)
CODE_ONLY="$TMP/bc-code.sh"; grep -v '^[[:space:]]*#' "$HOOKS/boot-catchup.sh" > "$CODE_ONLY"
glob_ln="$(grep -n '\.boot-context-\*' "$CODE_ONLY" | head -1 | cut -d: -f1)"
fork_ln="$(grep -nE '\$\(cat|jq |_lib\.sh' "$CODE_ONLY" | head -1 | cut -d: -f1)"
{ [ -n "$glob_ln" ] && [ -n "$fork_ln" ] && [ "$glob_ln" -lt "$fork_ln" ]; } \
  && ok "forkless fast-reject precedes cat/jq/_lib (code-only glob L$glob_ln < fork L$fork_ln)" \
  || bad "forkless fast-reject precedes cat/jq/_lib" "glob=$glob_ln fork=$fork_ln"

# ----------------------------------------------------------------------
# Layer 1: routing, STUB boot-inject, REAL hash resolution
# ----------------------------------------------------------------------
G="$TMP/gate/hooks"; mkdir -p "$G"
cp "$HOOKS/boot-catchup.sh" "$LIB" "$G/"
printf '#!/bin/bash\necho EXEC_BI\n' > "$G/boot-inject.sh"
chmod +x "$G/boot-catchup.sh" "$G/boot-inject.sh"

# This session's identity, anchored exactly how boot-inject will resolve it:
# CC-slug = basename(dirname(transcript_path)) == slugify($PROJ).
PROJ="$TMP/myproj"; mkdir -p "$PROJ"
PROJ_SLUG="$(printf '%s' "$PROJ" | sed 's|[/.]|-|g')"
FH="$TMP/fh"
TR="$FH/.claude/projects/$PROJ_SLUG/sid-x.jsonl"
mkdir -p "$(dirname "$TR")"; : > "$TR"
MYHASH="$(printf '%s' "$PROJ" | _mp_hash)"
[ -n "$MYHASH" ] || bad "_mp_hash produced a hash" "empty"
FOREIGN="$([ "$MYHASH" = "deadbeef" ] && echo cafef00d || echo deadbeef)"  # any hash != mine
STDIN_JSON="$(printf '{"hook_event_name":"PostToolUse","session_id":"sid-x","transcript_path":"%s","cwd":"%s","tool_name":"Bash","workspace":{"project_dir":"%s"}}' "$TR" "$PROJ" "$PROJ")"
run() { printf '%s' "$STDIN_JSON" | "$1" 2>/dev/null; }

# Case A: nothing waiting anywhere -> no exec, exit 0 (forkless path)
a="$(run "$G/boot-catchup.sh")"; ra=$?
{ [ -z "$a" ] && [ "$ra" -eq 0 ]; } \
  && ok "route: empty dir -> no exec, exit 0" || bad "route: empty dir -> no exec" "out=[$a] rc=$ra"

# Case D (THE SHARED-DIR BUG): only a FOREIGN project's live context present.
# Must NOT exec — that file is not ours.
: > "$G/.boot-context-$FOREIGN"
d="$(run "$G/boot-catchup.sh")"
[ -z "$d" ] \
  && ok "route: foreign .boot-context-<otherhash> only -> no exec (shared-dir safe)" \
  || bad "route: foreign .boot-context-<otherhash> only -> no exec" "out=[$d]"

# Case B: OUR live context present (foreign still there) -> exec boot-inject
: > "$G/.boot-context-$MYHASH"
b="$(run "$G/boot-catchup.sh")"
[ "$b" = "EXEC_BI" ] \
  && ok "route: our live .boot-context-<myhash> (amid foreign) -> exec" \
  || bad "route: our live .boot-context-<myhash> -> exec" "out=[$b]"

# Case B2: same as B but with camelCase-ONLY stdin (invariant #3 — CC field
# names drift between releases; a snake-only parse would resolve no hash and
# silently never catch up mid-turn).
CAMEL_JSON="$(printf '{"hookEventName":"PostToolUse","sessionId":"sid-x","transcriptPath":"%s","cwd":"%s","toolName":"Bash","workspace":{"projectDir":"%s"}}' "$TR" "$PROJ" "$PROJ")"
b2="$(printf '%s' "$CAMEL_JSON" | "$G/boot-catchup.sh" 2>/dev/null)"
[ "$b2" = "EXEC_BI" ] \
  && ok "route: camelCase-only stdin still resolves our hash -> exec" \
  || bad "route: camelCase-only stdin still resolves our hash -> exec" "out=[$b2]"

# Case C: only OUR carry-forward snapshot (+ foreign) -> no re-consume
rm -f "$G/.boot-context-$MYHASH"
: > "$G/.boot-context-last-$MYHASH"
c="$(run "$G/boot-catchup.sh")"
[ -z "$c" ] \
  && ok "route: only our .boot-context-last-<myhash> -> no re-consume" \
  || bad "route: only our .boot-context-last-<myhash> -> no re-consume" "out=[$c]"

# Mutation 1: strip the per-session hash guard -> foreign leaks through.
rm -f "$G/.boot-context-last-$MYHASH"            # leave only the foreign file
grep -vF "boot-context-\$_hash" "$G/boot-catchup.sh" > "$G/bc-nohashguard.sh"
chmod +x "$G/bc-nohashguard.sh"
m1="$(run "$G/bc-nohashguard.sh")"
[ "$m1" = "EXEC_BI" ] \
  && ok "mutation: removing hash guard re-leaks foreign context (guard live)" \
  || bad "mutation: removing hash guard re-leaks foreign context (guard live)" "out=[$m1]"

# Snapshot-only dir (only carry-forward .boot-context-last-* files, no live
# context anywhere) -> no exec. The -last- exclusion keeps this forkless;
# correctness against snapshots is redundant with the hash guard (Mutation 1),
# so this pins the behavior rather than mutating the perf-only exclusion.
rm -f "$G"/.boot-context-*
: > "$G/.boot-context-last-$MYHASH"
: > "$G/.boot-context-last-$FOREIGN"
s="$(run "$G/boot-catchup.sh")"
[ -z "$s" ] \
  && ok "route: snapshot-only dir (.boot-context-last-* only) -> no exec" \
  || bad "route: snapshot-only dir -> no exec" "out=[$s]"

# tmp-only dir: a RUNNING replay's .boot-context-<hash>.tmp.<pid> is not a
# live context — the forkless gate must reject it WITHOUT falling through to
# the stdin/jq/hash forks (for the minutes a replay runs, every tool call in
# every session of every project pays those forks otherwise). Observable via
# a PATH-stubbed jq that records any invocation.
rm -f "$G"/.boot-context-*
: > "$G/.boot-context-$MYHASH.tmp.999"
JQSTUB="$TMP/jqstub"; mkdir -p "$JQSTUB"
printf '#!/bin/sh\ntouch "%s/jq-forked"\nexit 1\n' "$TMP" > "$JQSTUB/jq"
chmod +x "$JQSTUB/jq"
t="$(printf '%s' "$STDIN_JSON" | PATH="$JQSTUB:$PATH" "$G/boot-catchup.sh" 2>/dev/null)"
{ [ -z "$t" ] && [ ! -f "$TMP/jq-forked" ]; } \
  && ok "route: tmp-only dir (.boot-context-<hash>.tmp.<pid>) -> forkless reject (no jq)" \
  || bad "route: tmp-only dir -> forkless reject" "out=[$t] jq-forked=$([ -f "$TMP/jq-forked" ] && echo y || echo n)"
rm -f "$G"/.boot-context-* "$TMP/jq-forked"

# ----------------------------------------------------------------------
# Layer 2: REAL boot-inject, EVENT=PostToolUse, end-to-end
# ----------------------------------------------------------------------
ENGINE="$TMP/engine/hooks"; mkdir -p "$ENGINE"
cp "$HOOKS/boot-catchup.sh" "$HOOKS/boot-inject.sh" "$LIB" "$ENGINE/"
chmod +x "$ENGINE/boot-catchup.sh" "$ENGINE/boot-inject.sh"
EPROJ="$TMP/eproj"; mkdir -p "$EPROJ"
EPROJ_SLUG="$(printf '%s' "$EPROJ" | sed 's|[/.]|-|g')"
EFH="$TMP/efh"
EMEM="$EFH/.claude/projects/$EPROJ_SLUG/memory"; mkdir -p "$EMEM"
ESID="esid-0"
ETR="$EFH/.claude/projects/$EPROJ_SLUG/$ESID.jsonl"; : > "$ETR"
EHASH="$(printf '%s' "$EPROJ" | _mp_hash)"
ESTDIN="$(printf '{"hook_event_name":"PostToolUse","session_id":"%s","transcript_path":"%s","cwd":"%s","tool_name":"Bash","workspace":{"project_dir":"%s"}}' "$ESID" "$ETR" "$EPROJ" "$EPROJ")"
erun() { printf '%s' "$ESTDIN" | HOME="$EFH" "$ENGINE/boot-catchup.sh" 2>/dev/null || true; }

# Regression #3 pin: a FOREIGN-only dir must corrupt nothing — no emit, and
# our pre-existing marker must NOT be flipped to "none".
: > "$ENGINE/.boot-context-$FOREIGN"
printf 'loaded' > "$ENGINE/.boot-marker-$ESID"
fo="$(erun)"
{ [ -z "$fo" ] && [ "$(cat "$ENGINE/.boot-marker-$ESID")" = "loaded" ]; } \
  && ok "e2e: foreign-only dir -> no emit, our marker untouched (no corruption)" \
  || bad "e2e: foreign-only dir -> no emit, marker untouched" "emit=[$fo] marker=[$(cat "$ENGINE/.boot-marker-$ESID" 2>/dev/null)]"

# Our live context lands mid-turn -> emitted as PostToolUse additionalContext.
# Designed precondition: the session has NOT already booted — SessionStart
# left the marker at "pending" (replay still running) or "none". A "loaded"
# marker means a fresh live context is a CONCURRENT session's — see the
# steal case below.
printf 'pending' > "$ENGINE/.boot-marker-$ESID"
printf 'TITLE: catchup-e2e\nSUMMARY: mid-turn injection works\n' > "$ENGINE/.boot-context-$EHASH"
OUT="$(erun)"
case "$OUT" in
  *'"hookEventName": "PostToolUse"'*) ok "e2e: emits hookEventName PostToolUse" ;;
  *) bad "e2e: emits hookEventName PostToolUse" "out=[$OUT]" ;;
esac
case "$OUT" in
  *"catchup-e2e"*) ok "e2e: additionalContext carries the boot context" ;;
  *) bad "e2e: additionalContext carries the boot context" "out=[$OUT]" ;;
esac
{ [ ! -f "$ENGINE/.boot-context-$EHASH" ] && [ -f "$ENGINE/.boot-context-last-$EHASH" ]; } \
  && ok "e2e: live context mv'd to .boot-context-last-<hash> (carry-forward)" \
  || bad "e2e: live context mv'd to .boot-context-last-<hash>" \
        "live=$([ -f "$ENGINE/.boot-context-$EHASH" ] && echo y||echo n) last=$([ -f "$ENGINE/.boot-context-last-$EHASH" ] && echo y||echo n)"

# Subsequent tool call in the same turn: our file consumed -> no re-injection
# (foreign file still present, must still be ignored).
OUT2="$(erun)"
[ -z "$OUT2" ] \
  && ok "e2e: after consume, further tool calls inject nothing (foreign ignored)" \
  || bad "e2e: after consume, further tool calls inject nothing" "out=[$OUT2]"

# Steal guard: a session that ALREADY booted (marker "loaded") must NOT
# consume a fresh live context mid-turn — that file is a concurrent
# same-project session's replay output; eating it here starves that
# session's successor ("[No boot context available]"). No emit, file intact.
printf 'loaded' > "$ENGINE/.boot-marker-$ESID"
printf 'TITLE: concurrent-fresh\nSUMMARY: belongs to the other session\n' > "$ENGINE/.boot-context-$EHASH"
OUT3="$(erun)"
{ [ -z "$OUT3" ] && [ -f "$ENGINE/.boot-context-$EHASH" ]; } \
  && ok "e2e: booted session (marker=loaded) steals nothing mid-turn (file intact)" \
  || bad "e2e: booted session (marker=loaded) steals nothing mid-turn" \
        "out=[$OUT3] live=$([ -f "$ENGINE/.boot-context-$EHASH" ] && echo intact || echo consumed)"
rm -f "$ENGINE/.boot-context-$EHASH"

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fail FAILED"; exit 1; fi
