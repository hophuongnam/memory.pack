#!/bin/bash
# Stop hook: block agent to assess whether hindsight retain is needed.
#
# Gate: Edit/Write tool calls since last retain (filters out read-only/chat sessions).
# Decision: agent's — it assesses whether the work warrants retaining.
# Loop guard: stop_hook_active prevents infinite blocking.
#
# Per-project config: place hindsight.conf next to this script with overrides:
#   BANK_ID="mybank"
#   EXTRA_TOOLS="replace_symbol_body|insert_after_symbol"
#   EXCLUDE_PATTERN='custom_pattern_here'

# Defaults
BANK_ID="default"
BASE_TOOLS="Edit|Write|Update"
EXTRA_TOOLS=""
EXCLUDE_PATTERN='\.claude/(projects|hooks|settings)/'

# Source per-project config if present (resolve symlinks to find conf next to actual script)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
REAL_DIR="$(cd "$SCRIPT_DIR" && cd "$(dirname "$(readlink "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")")" && pwd)"
for CONF_DIR in "$SCRIPT_DIR" "$REAL_DIR"; do
  if [ -f "$CONF_DIR/hindsight.conf" ]; then
    # shellcheck source=/dev/null
    . "$CONF_DIR/hindsight.conf"
    break
  fi
done

# Build tool pattern
TOOLS="$BASE_TOOLS"
if [ -n "$EXTRA_TOOLS" ]; then
  TOOLS="$TOOLS|$EXTRA_TOOLS"
fi
TOOL_PATTERN="\"($TOOLS)\""

INPUT=$(cat)
ALREADY_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

if [ "$ALREADY_ACTIVE" = "true" ]; then
  exit 0
fi

TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  LAST_RETAIN=$(grep -n 'mcp__hindsight__retain\|hindsight:skip' "$TRANSCRIPT" | tail -1 | cut -d: -f1)
  if [ -n "$LAST_RETAIN" ]; then
    if [ -n "$EXCLUDE_PATTERN" ]; then
      WORK_AFTER=$(tail -n +"$((LAST_RETAIN + 1))" "$TRANSCRIPT" | grep -E "$TOOL_PATTERN" | grep -cvE "$EXCLUDE_PATTERN")
    else
      WORK_AFTER=$(tail -n +"$((LAST_RETAIN + 1))" "$TRANSCRIPT" | grep -cE "$TOOL_PATTERN")
    fi
    if [ "$WORK_AFTER" -eq 0 ]; then
      exit 0
    fi
  else
    if [ -n "$EXCLUDE_PATTERN" ]; then
      WORK_ANY=$(grep -E "$TOOL_PATTERN" "$TRANSCRIPT" | grep -cvE "$EXCLUDE_PATTERN")
    else
      WORK_ANY=$(grep -cE "$TOOL_PATTERN" "$TRANSCRIPT")
    fi
    if [ "$WORK_ANY" -eq 0 ]; then
      exit 0
    fi
  fi
fi

echo "Code changes detected since last retain. Assess whether key outcomes need retaining to hindsight bank $BANK_ID, then proceed. If not worth retaining, include the exact phrase hindsight:skip in your response so this hook won't re-trigger for the same work." >&2
exit 2
