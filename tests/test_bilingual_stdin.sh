#!/bin/bash
# TDD: invariant #3 — EVERY hook parsing CC stdin must accept both
# snake_case and camelCase field names. CC's hook stdin field naming has
# drifted between releases (see reference_cc_hook_input_fields.md); a hook
# reading only one casing silently no-ops when the other arrives:
#   auto-save-stop.sh    → auto-save never triggers (transcript_path empty)
#   memory-recall.sh     → recall_count never bumps OR session dedup dies
#                          (empty session_id → every Read inflates the count
#                          → archived memories auto-promote after 3 reads in
#                          ONE session instead of 3 sessions)
#   archive-resurrect.sh → resurrect silently never runs
#   memory-index-update.sh → FTS index stale until SessionEnd reconcile
#
# Two layers (the project's accepted patterns):
#   1. structural source-regression — scan code-only lines of every
#      stdin-parsing hook: any JSON-accessor reference to a snake_case CC
#      field (jq `.field` or python 'field'/"field") must carry its camel
#      twin on the same line (the house `//` fallback idiom).
#   2. behavioral subprocess — feed camelCase-only stdin to the two hooks
#      whose failure mode is nastiest (auto-save-stop: silent no-trigger;
#      memory-recall: silent dedup loss) and assert the real effect.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HERE/../hooks"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# --- layer 1: structural — snake field never read without its camel twin --
# field pairs drifted by CC releases; `cwd` is identical in both casings.
PAIRS="session_id:sessionId
transcript_path:transcriptPath
hook_event_name:hookEventName
tool_name:toolName
tool_input:toolInput
stop_hook_active:stopHookActive
project_dir:projectDir
prompt:userPrompt"

# every hook that reads CC stdin (statusline included — it parses the same
# JSON shape). _lib.sh and the .mjs workers receive argv, not stdin.
FILES="boot-inject.sh session-end.sh auto-save-stop.sh log-token-rate.sh
memory-recall.sh memory-index-update.sh archive-resurrect.sh
memory-search-inject.sh"

for f in $FILES; do
  path="$HOOKS/$f"
  [ -f "$path" ] || { bad "$f exists" "missing $path"; continue; }
  code="$(grep -v '^[[:space:]]*#' "$path")"
  while IFS=: read -r snake camel; do
    [ -z "$snake" ] && continue
    # JSON-accessor forms only: jq `.field`, python `'field'` / `"field"`.
    # Shell vars like ${session_id} are NOT accessors and are skipped.
    viol=$(printf '%s\n' "$code" \
      | grep -E "(\.|'|\")${snake}\b" \
      | grep -v "$camel" || true)
    if [ -n "$viol" ]; then
      bad "$f: '$snake' read carries camel fallback '$camel'" "offending: $(printf '%s' "$viol" | head -2 | tr '\n' ' | ')"
    else
      ok "$f: '$snake' read carries camel fallback '$camel'"
    fi
  done <<EOF
$PAIRS
EOF
done

# statusline-command.sh parses the same stdin; check it too.
SL="$HERE/../statusline-command.sh"
code="$(grep -v '^[[:space:]]*#' "$SL")"
while IFS=: read -r snake camel; do
  [ -z "$snake" ] && continue
  viol=$(printf '%s\n' "$code" \
    | grep -E "(\.|'|\")${snake}\b" \
    | grep -v "$camel" || true)
  if [ -n "$viol" ]; then
    bad "statusline-command.sh: '$snake' carries '$camel'" "offending: $(printf '%s' "$viol" | head -2 | tr '\n' ' | ')"
  else
    ok "statusline-command.sh: '$snake' carries '$camel'"
  fi
done <<EOF
$PAIRS
EOF

# --- layer 2a: behavioral — auto-save-stop.sh with camelCase-only stdin ---
SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT
export HOME="$SBX"
mkdir -p "$HOME/.claude"

# 51 real string user turns → crosses SAVE_INTERVAL=50 on first Stop.
T="$SBX/transcript.jsonl"
: > "$T"
i=1
while [ "$i" -le 51 ]; do
  printf '{"type":"user","message":{"role":"user","content":"q%s"}}\n' "$i" >> "$T"
  i=$((i + 1))
done

# control: snake_case stdin triggers the save block (proves the fixture).
OUT_SNAKE=$(printf '{"session_id":"sid-snake-bi","stop_hook_active":false,"transcript_path":"%s"}' "$T" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT_SNAKE" in
  *'"decision"'*'"block"'*) ok "auto-save-stop: snake stdin triggers save block (control)" ;;
  *) bad "auto-save-stop: snake stdin triggers save block (control)" "out=$OUT_SNAKE" ;;
esac

# camelCase stdin must trigger identically.
OUT_CAMEL=$(printf '{"sessionId":"sid-camel-bi","stopHookActive":false,"transcriptPath":"%s"}' "$T" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT_CAMEL" in
  *'"decision"'*'"block"'*) ok "auto-save-stop: camelCase stdin triggers save block" ;;
  *) bad "auto-save-stop: camelCase stdin triggers save block" "out=$OUT_CAMEL" ;;
esac

# stopHookActive=true (camel) must let the stop through (no block).
OUT_ACTIVE=$(printf '{"sessionId":"sid-camel-bi2","stopHookActive":true,"transcriptPath":"%s"}' "$T" \
  | bash "$HOOKS/auto-save-stop.sh" 2>/dev/null)
case "$OUT_ACTIVE" in
  *'"decision"'*'"block"'*) bad "auto-save-stop: camel stopHookActive=true passes through" "blocked anyway: $OUT_ACTIVE" ;;
  *) ok "auto-save-stop: camel stopHookActive=true passes through" ;;
esac

# --- layer 2b: behavioral — memory-recall.sh with camelCase-only stdin ----
ENGINE="$SBX/engine/hooks"
mkdir -p "$ENGINE"
for f in memory-recall.sh update-recall.mjs _lib.mjs; do
  [ -f "$HOOKS/$f" ] && cp "$HOOKS/$f" "$ENGINE/"
done
chmod +x "$ENGINE/memory-recall.sh"

MEMDIR="$HOME/.claude/projects/-tmp-proj/memory"
mkdir -p "$MEMDIR"
MEMFILE="$MEMDIR/feedback_bilingual_fixture.md"
cat > "$MEMFILE" <<'MD'
---
name: feedback_bilingual_fixture
description: fixture
type: feedback
---

Body.
MD

printf '{"toolName":"Read","toolInput":{"file_path":"%s"},"sessionId":"sid-cam-recall"}' "$MEMFILE" \
  | bash "$ENGINE/memory-recall.sh" >/dev/null 2>&1

# updater is backgrounded — poll up to 3s for the frontmatter bump.
bumped=0
i=0
while [ "$i" -lt 6 ]; do
  if grep -q '^recall_count: 1$' "$MEMFILE" 2>/dev/null; then bumped=1; break; fi
  sleep 0.5
  i=$((i + 1))
done
[ "$bumped" -eq 1 ] \
  && ok "memory-recall: camelCase stdin bumps recall_count" \
  || bad "memory-recall: camelCase stdin bumps recall_count" "no bump after 3s: $(grep -c 'recall_count' "$MEMFILE" || true)"

# session dedup must hold: same camel session re-Read does NOT inflate.
printf '{"toolName":"Read","toolInput":{"file_path":"%s"},"sessionId":"sid-cam-recall"}' "$MEMFILE" \
  | bash "$ENGINE/memory-recall.sh" >/dev/null 2>&1
sleep 1
if grep -q '^recall_count: 1$' "$MEMFILE" 2>/dev/null; then
  ok "memory-recall: camel session_id preserves per-session dedup (count stays 1)"
else
  bad "memory-recall: camel session_id preserves per-session dedup (count stays 1)" \
      "got: $(grep '^recall_count' "$MEMFILE" 2>/dev/null)"
fi

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
