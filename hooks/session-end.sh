#!/bin/bash
# SessionEnd hook: launch replay of ending session.
# Replay runs detached via nohup; boot context written to .boot-context
# for the boot-inject hook to inject on the next session's first turn.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

INPUT=$(cat)
# Field-name aliases: CC's published hook docs say snake_case but the
# runtime hook stdin emits camelCase in some CC versions (see
# reference_cc_hook_input_fields.md). boot-inject.sh accepts both via jq
# `//`; this hook must do the same. When the PROJECT_DIR fallback
# misfires, replay writes the boot context to a hash that's the user's
# subdir (e.g. `.../NexusLit/src-tauri` after `cd src-tauri`), the next
# session in the actual project root looks for the project-root hash and
# sees nothing, and the replay agent is fed the wrong project's
# MEMORY.md / SESSIONS.md as well.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // .sessionId // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // .transcriptPath // empty')
# Prefer workspace.project_dir (stable across cd's) to match statusline-command.sh.
PROJECT_DIR=$(echo "$INPUT" | jq -r '.workspace.project_dir // .workspace.projectDir // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -z "$SESSION_ID" ] && exit 0

# Scope boot context + pid file per-project so project A's replay can't leak
# into project B's next session.
PROJECT_KEY="${PROJECT_DIR:-${CWD:-$PWD}}"
PROJECT_HASH=$(printf '%s' "$PROJECT_KEY" | md5 | head -c 8)
PROJECT_NAME=$(basename "$PROJECT_KEY" 2>/dev/null)
[ -z "$PROJECT_NAME" ] && PROJECT_NAME="unknown"
BOOT_CTX="$SCRIPT_DIR/.boot-context-${PROJECT_HASH}"
PID_FILE="$SCRIPT_DIR/.replay-pid-${PROJECT_HASH}"
ERR_MARKER="$SCRIPT_DIR/.replay-error-${PROJECT_HASH}"

# Skip trivial sessions (≤5 user turns)
TURNS=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TURNS=$(grep -c '"type":"user"' "$TRANSCRIPT" 2>/dev/null || echo 0)
fi
[ "$TURNS" -le 5 ] && exit 0

# Resolve replay script location (follow symlinks to find co-located replay.mjs)
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
REAL_DIR="$(cd "$SCRIPT_DIR" && cd "$(dirname "$(readlink "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")")" && pwd)"
REPLAY="$REAL_DIR/replay.mjs"
[ ! -f "$REPLAY" ] && REPLAY="$SCRIPT_DIR/replay.mjs"

# Clean stale boot context, PID file, and error marker for this project.
# The error marker is only meaningful between runs — the new run either
# clears it (success / benign no-op) or re-writes it (failure).
rm -f "$BOOT_CTX" "$BOOT_CTX.tmp" "$PID_FILE" "$ERR_MARKER"

# Drop this session's boot marker and prune stale markers (>3 days).
[ -n "$SESSION_ID" ] && rm -f "$SCRIPT_DIR/.boot-marker-${SESSION_ID}"
find "$SCRIPT_DIR" -maxdepth 1 -name '.boot-marker-*' -mtime +3 -delete 2>/dev/null

# Detach replay. Three outcomes:
#   success (exit 0, non-empty stdout) → move tmp into place, notify "finished"
#   benign no-op (exit 2)              → silent cleanup, no notification
#   failure (exit 3 / crash / empty)   → write a synthetic error boot-context
#                                        so the NEXT session's boot-inject
#                                        surfaces the error directly in
#                                        Claude's context, plus a marker file
#                                        the statusline can read, plus the
#                                        macOS "failed" notification.
#
# The synthetic boot-context mimics replay.mjs's TITLE/SUMMARY/TODO/DECISIONS
# format so boot-inject.sh treats it uniformly. The SUMMARY embeds the tail of
# /tmp/replay-error.log so the failure is self-reporting — no need to cat a log.
nohup sh -c "echo \$\$ >\"$PID_FILE\"; \
  osascript -e 'display notification \"Replay started\" with title \"Claude Code · $PROJECT_NAME\"' >/dev/null 2>&1 || true; \
  node \"$REPLAY\" \"$SESSION_ID\" \"$PROJECT_KEY\" \
  >\"$BOOT_CTX.tmp\" 2>/tmp/replay-error.log; \
  STATUS=\$?; \
  if [ \$STATUS -eq 0 ] && [ -s \"$BOOT_CTX.tmp\" ]; then \
    mv \"$BOOT_CTX.tmp\" \"$BOOT_CTX\"; \
    rm -f \"$ERR_MARKER\"; \
    osascript -e 'display notification \"Replay finished\" with title \"Claude Code · $PROJECT_NAME\"' >/dev/null 2>&1 || true; \
  elif [ \$STATUS -eq 2 ]; then \
    rm -f \"$BOOT_CTX.tmp\" \"$ERR_MARKER\"; \
  else \
    rm -f \"$BOOT_CTX.tmp\"; \
    ERR_TAIL=\$(tail -c 400 /tmp/replay-error.log 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g; s/^ *//; s/ *$//'); \
    [ -z \"\$ERR_TAIL\" ] && ERR_TAIL=\"(no stderr captured; exit \$STATUS with empty stdout)\"; \
    printf 'TITLE: Replay failed for prior session\nSUMMARY: replay.mjs exited %s. stderr tail: %s\nTODO: investigate /tmp/replay-error.log and Memory.Pack/hooks/replay.mjs — the prior session was not summarized\nDECISIONS: none\n' \"\$STATUS\" \"\$ERR_TAIL\" > \"$BOOT_CTX\"; \
    printf 'exit=%s\nreason=%s\n' \"\$STATUS\" \"\$ERR_TAIL\" > \"$ERR_MARKER\"; \
    osascript -e 'display notification \"Replay failed — see /tmp/replay-error.log\" with title \"Claude Code · $PROJECT_NAME\"' >/dev/null 2>&1 || true; \
  fi; \
  rm -f \"$PID_FILE\"" </dev/null &>/dev/null &
disown
