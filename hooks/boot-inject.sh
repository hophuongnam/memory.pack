#!/bin/bash
# Inject boot context from previous session's replay.
# Wired to both SessionStart (immediate) and UserPromptSubmit (fallback).
# Checks for .boot-context written by session-end.sh.
INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "UserPromptSubmit"')
# Prefer workspace.project_dir (stable across cd's) to match statusline-command.sh.
PROJECT_DIR=$(echo "$INPUT" | jq -r '.workspace.project_dir // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Scope boot context + pid file per-project so we don't inject project A's
# replay into project B's next session.
PROJECT_KEY="${PROJECT_DIR:-${CWD:-$PWD}}"
PROJECT_HASH=$(printf '%s' "$PROJECT_KEY" | md5 | head -c 8)
# Slug mirrors Claude Code's project dir naming: abs cwd with `/` and `.` → `-`.
PROJECT_SLUG=$(printf '%s' "$PROJECT_KEY" | sed 's|[/.]|-|g')
MEMORY_DIR="$HOME/.claude/projects/${PROJECT_SLUG}/memory"
SESSION_LOG="$MEMORY_DIR/sessions.log.md"
SESSIONS_INDEX="$MEMORY_DIR/SESSIONS.md"
PENDING_FILE="$MEMORY_DIR/PENDING_MEMORIES.md"
BOOT_CTX="$SCRIPT_DIR/.boot-context-${PROJECT_HASH}"
PID_FILE="$SCRIPT_DIR/.replay-pid-${PROJECT_HASH}"
# Session-scoped marker read by statusline to render the real boot state
# (loaded / pending / none) instead of guessing from the absence of BOOT_CTX.
MARKER_FILE="$SCRIPT_DIR/.boot-marker-${SESSION_ID}"

# Check if replay is still running
replay_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

# Read prior marker state (if any). boot-inject runs on both SessionStart
# and every UserPromptSubmit. Once this session has reached a terminal
# boot state (loaded or none), re-running on later UserPromptSubmits must
# not demote the marker or re-emit the one-shot status line — doing so
# produces contradictory messages ("loaded" at SessionStart, "no context"
# one turn later) and desyncs the statusline. Only "pending" is
# non-terminal and warrants re-evaluation (replay may finish mid-session).
PRIOR_MARKER=""
[ -n "$SESSION_ID" ] && [ -f "$MARKER_FILE" ] && PRIOR_MARKER=$(cat "$MARKER_FILE" 2>/dev/null)
if [ "$EVENT" = "UserPromptSubmit" ] && [ -n "$PRIOR_MARKER" ] && [ "$PRIOR_MARKER" != "pending" ]; then
  # "loaded" is truly terminal. "none" is terminal UNLESS replay finished
  # after the marker was set (race: replay completes between SessionStart
  # and the next UserPromptSubmit). In that case, re-evaluate.
  if [ "$PRIOR_MARKER" = "loaded" ] || [ ! -f "$BOOT_CTX" ]; then
    exit 0
  fi
fi

CONTEXT=""

if [ "$EVENT" = "SessionStart" ] && [ ! -f "$BOOT_CTX" ] && replay_running; then
  # Short poll (up to 10s) so a replay that's seconds from finishing still
  # lands in the SessionStart injection instead of deferring to the
  # UserPromptSubmit fallback. Early-exits the moment the file appears or
  # the replay process dies.
  i=0
  while [ "$i" -lt 10 ]; do
    sleep 1
    i=$((i + 1))
    if [ -f "$BOOT_CTX" ]; then
      break
    fi
    replay_running || break
  done
fi

if [ "$EVENT" = "UserPromptSubmit" ] && [ ! -f "$BOOT_CTX" ] && replay_running; then
  # Poll up to 60s for replay to finish. Replay is a Claude agent and
  # routinely takes 20-40s; a short window meant the first prompt often
  # raced past a still-running replay and lost the boot context injection
  # (the archive in sessions.log.md survives, but in-conversation context
  # does not). Early-exit the loop as soon as the file appears or the
  # replay process dies, so the 60s is a ceiling, not a floor.
  i=0
  while [ "$i" -lt 60 ]; do
    sleep 1
    i=$((i + 1))
    if [ -f "$BOOT_CTX" ]; then
      break
    fi
    replay_running || break
  done
fi

STATUS=""
MARKER_STATE=""
if [ -f "$BOOT_CTX" ]; then
  CONTEXT=$(cat "$BOOT_CTX")
  # Archive the replay output to a per-project append-only session log so
  # the structured summary (TITLE/SUMMARY/TODO/DECISIONS) outlives the
  # one-shot boot injection.
  if [ -d "$MEMORY_DIR" ]; then
    if [ ! -f "$SESSION_LOG" ]; then
      cat > "$SESSION_LOG" <<'HEADER'
# Session Log

Append-only archive of replay-agent boot contexts from prior sessions in
this project. Written by `Memory.Pack/hooks/boot-inject.sh` right before
the one-shot boot context file is consumed. Each entry is the structured
output of the replay agent (TITLE / SUMMARY / TODO / DECISIONS).

Not a memory file — `memory-lint` ignores this path.

---
HEADER
    fi
    {
      printf '\n## %s  —  session %s\n\n' "$(date '+%Y-%m-%d %H:%M %Z')" "${SESSION_ID:-unknown}"
      printf '%s\n' "$CONTEXT"
    } >> "$SESSION_LOG"

    # Cross-session index: one-line-per-session timeline that replay.mjs
    # reads on the next SessionEnd so pass 1 / pass 2 prompts can spot
    # continuity across prior sessions. Extract TITLE from the boot context;
    # skip the index write if the agent's output was malformed.
    TITLE_LINE=$(printf '%s\n' "$CONTEXT" | grep -m1 '^TITLE:' | sed 's/^TITLE:[[:space:]]*//')
    if [ -n "$TITLE_LINE" ]; then
      if [ ! -f "$SESSIONS_INDEX" ]; then
        cat > "$SESSIONS_INDEX" <<'IHEADER'
# Session Index

One-line-per-session timeline of prior session outputs in this project.
Newest last. Maintained by `Memory.Pack/hooks/boot-inject.sh` at the same
time the full replay is archived to `sessions.log.md`. `replay.mjs` reads
the last N entries to feed cross-session continuity into the next
SessionEnd's boot-context and memory-promotion passes.

Not a memory file — `memory-lint` ignores this path.

---

IHEADER
      fi
      printf '%s  ·  %s  ·  %s\n' "$(date '+%Y-%m-%d %H:%M %Z')" "${SESSION_ID:-unknown}" "$TITLE_LINE" >> "$SESSIONS_INDEX"
    fi
  fi
  rm -f "$BOOT_CTX"
  STATUS="[Boot context loaded from previous session.]"
  MARKER_STATE="loaded"
elif replay_running; then
  STATUS="[Previous session replay is still processing.]"
  MARKER_STATE="pending"
else
  STATUS="[No boot context available from previous session.]"
  MARKER_STATE="none"
fi

if [ -n "$SESSION_ID" ]; then
  printf '%s' "$MARKER_STATE" > "$MARKER_FILE"
fi

# Safety-net sweep mirroring session-end.sh:46 — catches markers left behind
# when SessionEnd didn't fire (CC crash, kill, OS reboot). Same 3-day threshold.
if [ "$EVENT" = "SessionStart" ]; then
  find "$SCRIPT_DIR" -maxdepth 1 -name '.boot-marker-*' -mtime +3 -delete 2>/dev/null
fi

if [ -n "$CONTEXT" ]; then
  CONTEXT="$STATUS

$CONTEXT"
else
  CONTEXT="$STATUS"
fi

# Independent reminder: if pending memory proposals exist for this project
# (either freshly appended by this replay or carried over from a past one
# that wasn't fully processed), surface a one-line nudge so the next turn's
# Claude reviews them. Count proposal blocks to avoid crying wolf on empty
# files.
if [ -f "$PENDING_FILE" ]; then
  # grep -c prints the count (0 if no match) but exits 1 on zero matches,
  # so capture stdout and default-to-0 only when grep couldn't read the file.
  PENDING_COUNT=$(grep -c '^PROPOSAL$' "$PENDING_FILE" 2>/dev/null || true)
  PENDING_COUNT=${PENDING_COUNT:-0}
  if [ "$PENDING_COUNT" -gt 0 ]; then
    CONTEXT="$CONTEXT

[${PENDING_COUNT} pending memory proposal(s) in memory/PENDING_MEMORIES.md — follow the review protocol at the top of that file before ending the session.]"
  fi
fi

if [ -n "$CONTEXT" ]; then
  jq -n --arg ctx "$CONTEXT" --arg event "$EVENT" '{
    hookSpecificOutput: {
      hookEventName: $event,
      additionalContext: $ctx
    }
  }'
fi

exit 0
