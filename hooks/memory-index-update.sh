#!/bin/bash
# PostToolUse hook — keep the auto-memory FTS5 index in sync after a Write,
# Edit, or MultiEdit to a memory file. Single-file upsert, backgrounded
# so the hook returns instantly and never gates the agent.
#
# Race note vs archive-resurrect.sh: both fire on PostToolUse:Write. The
# resurrector only mutates frontmatter fields (created/recall_count/
# last_reviewed/last_recalled) — none of which are FTS columns — so even
# if the indexer wins the race and reads the pre-resurrect file, the
# searchable content (type/name/description/body) is identical. The full
# reconcile at SessionEnd catches anything else (manual mv, git restore,
# /memory-lint deletions).

INPUT=$(cat)

# Bilingual snake↔camel per invariant #3 (reference_cc_hook_input_fields.md).
TOOL=$(echo "$INPUT" | jq -r '.tool_name // .toolName // empty')
case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '(.tool_input // .toolInput // {}).file_path // empty')
[ -n "$FILE_PATH" ] || exit 0

# Only memory files under ~/.claude/projects/<slug>/memory/ — including
# anything under archive/ at ANY depth: in a `case` pattern `*` crosses
# `/` (fnmatch without FNM_PATHNAME), so this single glob already matches
# nested archive/sub/ paths. More permissive than archive-resurrect.sh by
# design (that hook deliberately skips archive/ writes).
case "$FILE_PATH" in
  "$HOME"/.claude/projects/*/memory/*.md) ;;
  *) exit 0 ;;
esac

# Skip derived/meta files — but NOT sessions.log.md: the indexer
# deliberately indexes session logs as type=session (index-memories.py
# SKIP_BASENAMES comment). Skipping it here left live session-log writes
# stale in the index until the SessionEnd reconcile. Deliberately narrower
# than archive-resurrect.sh's skip list.
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  MEMORY.md|SESSIONS.md|PENDING_MEMORIES.md|SCHEMA.md) exit 0 ;;
  .*) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INDEXER="$SCRIPT_DIR/../index/index-memories.py"

# Background and disown so the hook returns in <10ms.
nohup python3 "$INDEXER" --file "$FILE_PATH" --quiet \
  >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0
