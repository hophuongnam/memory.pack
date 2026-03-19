#!/bin/bash
# UserPromptSubmit hook: inject Hindsight boot context if async replay is done.
# Checks for .hindsight-boot-context written by hindsight-session-start.sh.
# Outputs additionalContext JSON once, then deletes the file.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOT_CTX="$SCRIPT_DIR/.hindsight-boot-context"

if [ -f "$BOOT_CTX" ]; then
  CONTEXT=$(cat "$BOOT_CTX")
  rm -f "$BOOT_CTX"
  if [ -n "$CONTEXT" ]; then
    jq -n --arg ctx "$CONTEXT" '{
      hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: $ctx
      }
    }'
    exit 0
  fi
fi
