#!/bin/bash
# TDD: PROJECT_HASH must derive from CC's authoritative slug
# (= basename of dirname of transcript_path), not from the live cwd.
#
# Bug: when a session's user `cd`s into a subfolder, session-end.sh's
# `PROJECT_KEY="${PROJECT_DIR:-${CWD:-$PWD}}"` falls through to `.cwd`
# (the camel/snake `workspace.project_dir` field is unreliable in some CC
# versions — boot-context-947df9d4 in Pre.Audit proves this in active use,
# Green.World subfolder hash holding content that belongs to Pre.Audit's
# e5edaabc store). session-end then writes `.boot-context-<subfolder-hash>`,
# the next session at the project root reads `.boot-context-<parent-hash>`,
# sees nothing → "[No boot context available]" → silent amnesia.
# This is the writer↔CC path-parity analog of invariant #4 (project slug).
#
# transcript_path is the only stdin field that's *anchored to CC's own slug
# decision* — CC put the JSONL where it put it; basename(dirname(transcript))
# IS the canonical slug. Walk up from .cwd to the ancestor whose
# [/.] → - slugification equals CC's slug; THAT ancestor is the project root.
#
# Three layers, mirroring the project's two accepted patterns:
#   1. structural source-regression — _lib.sh exposes the resolver; both
#      hooks call it (not the bare cwd-fallback chain alone).
#   2. behavioral subprocess (boot-inject.sh) — feed it stdin where
#      transcript_path points to PARENT slug, cwd is subfolder, workspace
#      empty (the real bug scenario); assert PARENT-hash boot-context is
#      consumed.
#   3. mutation — re-run with boot-contexts at BOTH parent AND subfolder
#      hashes; assert PARENT content wins regardless of cwd.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SE="$HERE/../hooks/session-end.sh"
BI="$HERE/../hooks/boot-inject.sh"
LIB="$HERE/../hooks/_lib.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fail=$((fail+1)); }

for f in "$SE" "$BI" "$LIB"; do
  [ -f "$f" ] || { echo "FAIL  missing $f"; exit 1; }
done

# --- layer 1: structural source-regression ------------------------------
# Strip comment lines (optional leading whitespace then '#') so cautionary
# comments naming the legacy pattern cannot trip the guard.
CODE_SE="$(grep -v '^[[:space:]]*#' "$SE")"
CODE_BI="$(grep -v '^[[:space:]]*#' "$BI")"

# Helper must exist in _lib.sh — both hooks lean on it for parity.
if grep -q '^_mp_resolve_project_key()' "$LIB"; then
  ok "_lib.sh exports _mp_resolve_project_key"
else
  bad "_lib.sh exports _mp_resolve_project_key" \
      "helper not defined — hooks have no shared transcript-anchored resolver"
fi

# Both hooks must invoke the resolver (or otherwise derive the slug from
# transcript_path). The bare cwd-fallback alone follows the user's cd.
if printf '%s\n' "$CODE_SE" | grep -q '_mp_resolve_project_key'; then
  ok "session-end.sh uses _mp_resolve_project_key for slug anchoring"
else
  bad "session-end.sh uses _mp_resolve_project_key for slug anchoring" \
      "cwd-based PROJECT_KEY only — sessions that cd into subfolders silent-amnesia"
fi

if printf '%s\n' "$CODE_BI" | grep -q '_mp_resolve_project_key'; then
  ok "boot-inject.sh uses _mp_resolve_project_key for slug anchoring"
else
  bad "boot-inject.sh uses _mp_resolve_project_key for slug anchoring" \
      "cwd-based PROJECT_KEY only — next-session boot-context lookup mis-targets"
fi

# --- layer 2: behavioral subprocess -------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Stage a fake engine in $TMP so we don't touch the real hooks/ state.
ENGINE="$TMP/engine"
mkdir -p "$ENGINE/hooks"
cp "$SE" "$BI" "$LIB" "$ENGINE/hooks/"
chmod +x "$ENGINE/hooks/boot-inject.sh" "$ENGINE/hooks/session-end.sh"

# Fake CC project tree: PARENT is the launch dir; SUB is where the user
# cd'd to mid-session. Mirror Pre.Audit/Projects/Green.World.2026.
PARENT_REAL="$TMP/Pre.Audit"
SUB_REAL="$PARENT_REAL/Projects/Green.World.2026"
mkdir -p "$SUB_REAL"

# CC's slug for $PARENT_REAL (sed mirrors boot-inject.sh:38 / replay.mjs:89).
# shellcheck disable=SC1090
. "$LIB"
PARENT_HASH="$(printf '%s' "$PARENT_REAL" | _mp_hash)"
SUB_HASH="$(printf '%s' "$SUB_REAL"    | _mp_hash)"
PARENT_SLUG="$(printf '%s' "$PARENT_REAL" | sed 's|[/.]|-|g')"
[ -n "$PARENT_HASH" ] && [ -n "$SUB_HASH" ] && [ "$PARENT_HASH" != "$SUB_HASH" ] \
  || { echo "FAIL  fixture: parent/sub hashes empty or equal"; exit 1; }

# Override HOME so MEMORY_DIR resolves into $TMP, not the real ~/.claude.
FAKE_HOME="$TMP/fake-home"
TRANSCRIPT_DIR="$FAKE_HOME/.claude/projects/$PARENT_SLUG"
mkdir -p "$TRANSCRIPT_DIR/memory"
SID="test-slug-anchor-0000"
TRANSCRIPT="$TRANSCRIPT_DIR/$SID.jsonl"
: > "$TRANSCRIPT"

# Place boot-context at PARENT hash with known content.
printf 'TITLE: parent-only test\nSUMMARY: parent-anchored\n' > "$ENGINE/hooks/.boot-context-${PARENT_HASH}"

# Mimic the real bug: workspace empty (CC version with no workspace.project_dir),
# cwd in subfolder, transcript_path in PARENT slug dir.
STDIN_JSON="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","transcript_path":"%s","cwd":"%s","workspace":{}}' "$SID" "$TRANSCRIPT" "$SUB_REAL")"

OUT="$(HOME="$FAKE_HOME" printf '%s' "$STDIN_JSON" | HOME="$FAKE_HOME" "$ENGINE/hooks/boot-inject.sh" 2>/dev/null || true)"

case "$OUT" in
  *"parent-only test"*) ok "boot-inject loads PARENT-hash context when cwd=subfolder + transcript=parent" ;;
  *) bad "boot-inject loads PARENT-hash context when cwd=subfolder + transcript=parent" \
         "expected 'parent-only test' in output | out=[$OUT]" ;;
esac

# --- layer 3: mutation -------------------------------------------------
# Restore PARENT context (the prior boot-inject moved it to .boot-context-last-).
# ALSO place a different SUB-hash boot-context. Correct resolver picks
# PARENT regardless of cwd; cwd-based picks SUB and leaks subfolder content.
printf 'TITLE: parent-only test\nSUMMARY: parent-anchored\n' > "$ENGINE/hooks/.boot-context-${PARENT_HASH}"
printf 'TITLE: subfolder-wrong test\nSUMMARY: must-never-load\n' > "$ENGINE/hooks/.boot-context-${SUB_HASH}"
# Fresh SID so the prior-marker terminal-state shortcut doesn't kick in.
SID2="test-slug-anchor-1111"
TRANSCRIPT2="$TRANSCRIPT_DIR/$SID2.jsonl"
: > "$TRANSCRIPT2"
STDIN_JSON2="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","transcript_path":"%s","cwd":"%s","workspace":{}}' "$SID2" "$TRANSCRIPT2" "$SUB_REAL")"

OUT2="$(HOME="$FAKE_HOME" printf '%s' "$STDIN_JSON2" | HOME="$FAKE_HOME" "$ENGINE/hooks/boot-inject.sh" 2>/dev/null || true)"

case "$OUT2" in
  *"subfolder-wrong test"*)
    bad "mutation: PARENT context wins even when SUB context also exists" \
        "subfolder content leaked through — resolver still cwd-based | out=[$OUT2]" ;;
  *"parent-only test"*)
    ok "mutation: PARENT context wins even when SUB context also exists" ;;
  *)
    bad "mutation: PARENT context wins even when SUB context also exists" \
        "no recognizable content loaded | out=[$OUT2]" ;;
esac

# --- layer 3b: empty project_dir AND cwd (IFS-tab field collapse) ------
# CC stdin with workspace.project_dir="" and cwd="" used to field-shift the
# @tsv+IFS-tab read (tab is IFS *whitespace*: runs collapse, empty fields
# vanish) — PROJECT_DIR received the SESSION ID string, the resolver walked
# a junk path, and PROJECT_HASH pointed nowhere. With a non-whitespace
# separator the empty fields survive positionally and the $PWD fallback +
# transcript-anchored resolver find the project (the hook's cwd IS the
# project here, as in a real session).
rm -f "$ENGINE/hooks/.boot-context-${SUB_HASH}"
printf 'TITLE: empty-fields test\nSUMMARY: US-separated parse\n' > "$ENGINE/hooks/.boot-context-${PARENT_HASH}"
SID_EF="test-slug-anchor-3333"
TRANSCRIPT_EF="$TRANSCRIPT_DIR/$SID_EF.jsonl"
: > "$TRANSCRIPT_EF"
STDIN_EF="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","transcript_path":"%s","cwd":"","workspace":{"project_dir":""}}' "$SID_EF" "$TRANSCRIPT_EF")"
OUT_EF="$(cd "$PARENT_REAL" && printf '%s' "$STDIN_EF" | HOME="$FAKE_HOME" "$ENGINE/hooks/boot-inject.sh" 2>/dev/null || true)"
case "$OUT_EF" in
  *"empty-fields test"*) ok "boot-inject survives empty project_dir+cwd (no IFS-tab field shift)" ;;
  *) bad "boot-inject survives empty project_dir+cwd (no IFS-tab field shift)" \
         "expected 'empty-fields test' | out=[$OUT_EF]" ;;
esac

# --- layer 4: statusline parity (invariant #2) -------------------------
# statusline-command.sh must derive the SAME PROJECT_HASH as the hooks so
# .skip-replay-<hash> targets the same sentinel. Mirror the same scenario:
# workspace.project_dir = SUB (or empty), transcript_path = PARENT slug;
# place a sentinel at the PARENT hash; assert ⏭skip-replay renders.
SL="$HERE/../statusline-command.sh"
[ -f "$SL" ] || { echo "FAIL  statusline-command.sh missing ($SL)"; exit 1; }

# Stage statusline beside the engine hooks dir, invoked via an absolute
# symlink so its self-location resolves $MP_HOOKS_DIR to $ENGINE/hooks (the
# install.sh layout). This mirrors test_statusline_marker_path.sh.
SL_PREFIX="$TMP/sl-prefix"
mkdir -p "$SL_PREFIX"
cp "$SL" "$SL_PREFIX/statusline-command.sh"
chmod +x "$SL_PREFIX/statusline-command.sh"
# hooks/ sibling for self-location to land in
mkdir -p "$SL_PREFIX/hooks"
cp "$ENGINE/hooks/.boot-context-${PARENT_HASH}" "$SL_PREFIX/hooks/" 2>/dev/null || true
# Copy render helpers so the relocated statusline-command.sh can source them.
# (These live in the real hooks/ — not in $ENGINE which is a minimal fixture.)
for _f in _lib.sh statusline-theme.sh statusline-icons.sh statusline-render.sh; do
  cp "$HERE/../hooks/$_f" "$SL_PREFIX/hooks/"
done
# Place the skip-replay sentinel at the PARENT hash (what hooks now write).
: > "$SL_PREFIX/hooks/.skip-replay-${PARENT_HASH}"
SL_LINK="$TMP/sl-fake-claude/statusline-command.sh"
mkdir -p "$(dirname "$SL_LINK")"
ln -s "$SL_PREFIX/statusline-command.sh" "$SL_LINK"

# Statusline input: workspace.project_dir = SUB (the buggy field value),
# transcript_path = PARENT slug. Correct resolver walks up to PARENT.
SID3="test-slug-anchor-2222"
TRANSCRIPT3="$TRANSCRIPT_DIR/$SID3.jsonl"
: > "$TRANSCRIPT3"
SL_STDIN="$(printf '{"session_id":"%s","transcript_path":"%s","workspace":{"project_dir":"%s"},"model":{"display_name":"m"},"context_window":{"used_percentage":1}}' "$SID3" "$TRANSCRIPT3" "$SUB_REAL")"
SL_OUT="$(printf '%s' "$SL_STDIN" | "$SL_LINK" 2>/dev/null || true)"

case "$SL_OUT" in
  *"⏭skip-replay"*) ok "statusline ⏭skip-replay parity (transcript anchors hash to PARENT)" ;;
  *) bad "statusline ⏭skip-replay parity (transcript anchors hash to PARENT)" \
         "sentinel at PARENT hash not picked up — invariant #2 violated | out=[$SL_OUT]" ;;
esac

# Mutation: ALSO drop a sentinel at SUB hash and confirm PARENT is what
# matters (cwd-based logic would still resolve here because workspace=SUB).
# Both sentinels present → the PARENT one is what statusline must look at.
: > "$SL_PREFIX/hooks/.skip-replay-${SUB_HASH}"
SL_OUT2="$(printf '%s' "$SL_STDIN" | "$SL_LINK" 2>/dev/null || true)"
# We can't directly tell which sentinel triggered the indicator, so prove
# parity by REMOVING the PARENT sentinel and keeping only SUB — the
# correct resolver should now NOT render the indicator, because hooks
# would never have written a SUB-hash sentinel.
rm -f "$SL_PREFIX/hooks/.skip-replay-${PARENT_HASH}"
SL_OUT3="$(printf '%s' "$SL_STDIN" | "$SL_LINK" 2>/dev/null || true)"
case "$SL_OUT3" in
  *"⏭skip-replay"*)
    bad "statusline does NOT honor a SUB-hash-only sentinel (parity check)" \
        "indicator fired off a hash that hooks never write | out=[$SL_OUT3]" ;;
  *) ok "statusline does NOT honor a SUB-hash-only sentinel (parity check)" ;;
esac

# --- layer 5: statusline memory-indicator parity (invariant #4 read side) --
# The mem_dir lookup must use the SAME transcript-anchored project key and
# the SAME [/.] → - slug encoding as the engine. The legacy code derived it
# from raw workspace.project_dir with a [^a-zA-Z0-9] → - encoding:
#   * empty project_dir (the documented CC bug the resolver exists for) or
#     a mid-session `cd` → wrong/missing store → indicator silently absent
#   * any path containing `_` encodes differently than CC's slug → ditto
SID4="test-slug-anchor-3333"
TRANSCRIPT4="$TRANSCRIPT_DIR/$SID4.jsonl"
: > "$TRANSCRIPT4"
# Memory store with a known line count at the PARENT slug.
printf '%s\n' 1 2 3 4 5 6 7 8 9 10 > "$TRANSCRIPT_DIR/memory/MEMORY.md"

# Real bug shape: workspace EMPTY, cwd in subfolder, transcript at PARENT.
SL_STDIN4="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","workspace":{},"model":{"display_name":"m"},"context_window":{"used_percentage":1}}' "$SID4" "$TRANSCRIPT4" "$SUB_REAL")"
SL_OUT4="$(printf '%s' "$SL_STDIN4" | HOME="$FAKE_HOME" "$SL_LINK" 2>/dev/null || true)"
case "$SL_OUT4" in
  *"10/150"*) ok "statusline mem indicator resolves store via transcript anchor (project_dir empty, cwd=subfolder)" ;;
  *) bad "statusline mem indicator resolves store via transcript anchor (project_dir empty, cwd=subfolder)" \
         "expected '10/150' | out=[$SL_OUT4]" ;;
esac

# Encoding pin: underscore survives CC's [/.] → - slug; the legacy
# [^a-zA-Z0-9] → - encoding flattened it and missed the store.
PARENT_U="$TMP/Under_Score.Proj"
mkdir -p "$PARENT_U"
PARENT_U_SLUG="$(printf '%s' "$PARENT_U" | sed 's|[/.]|-|g')"
TRANSCRIPT_DIR_U="$FAKE_HOME/.claude/projects/$PARENT_U_SLUG"
mkdir -p "$TRANSCRIPT_DIR_U/memory"
printf '%s\n' 1 2 3 4 5 6 7 8 9 10 11 12 > "$TRANSCRIPT_DIR_U/memory/MEMORY.md"
SID5="test-slug-anchor-4444"
TRANSCRIPT5="$TRANSCRIPT_DIR_U/$SID5.jsonl"
: > "$TRANSCRIPT5"
SL_STDIN5="$(printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","workspace":{"project_dir":"%s"},"model":{"display_name":"m"},"context_window":{"used_percentage":1}}' "$SID5" "$TRANSCRIPT5" "$PARENT_U" "$PARENT_U")"
SL_OUT5="$(printf '%s' "$SL_STDIN5" | HOME="$FAKE_HOME" "$SL_LINK" 2>/dev/null || true)"
case "$SL_OUT5" in
  *"12/150"*) ok "statusline mem indicator uses engine slug encoding (underscore path)" ;;
  *) bad "statusline mem indicator uses engine slug encoding (underscore path)" \
         "expected '12/150' | out=[$SL_OUT5]" ;;
esac

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fail FAILED"; exit 1; fi
