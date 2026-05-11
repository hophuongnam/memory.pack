#!/bin/bash
# Inject boot context from previous session's replay.
# Wired to both SessionStart (immediate) and UserPromptSubmit (fallback).
# Checks for .boot-context written by session-end.sh.
INPUT=$(cat)
# Single jq call extracts all four fields together — each separate jq fork
# is ~30-40ms on macOS, and four serial calls pushed the early marker write
# below past the 50ms window where statusline-command.sh races us. Tab
# delimiter is safe because none of these fields can contain tabs.
#
# Field-name aliases: CC's published hook docs say snake_case
# (`session_id`, `hook_event_name`), but the runtime hook stdin emits
# camelCase (`sessionId`, `hookEventName`) in some CC versions. Accept
# both via jq `//` fallback so the marker write doesn't silently no-op
# when CC's field naming flips. Symptom we hit: SessionStart hook ran in
# 164ms with a successful stdout, but no `.boot-marker-${SESSION_ID}`
# file landed because SESSION_ID parsed empty → marker write was gated
# off.
IFS=$'\t' read -r EVENT PROJECT_DIR CWD SESSION_ID <<<"$(echo "$INPUT" | jq -r '[.hook_event_name // .hookEventName // "UserPromptSubmit", .workspace.project_dir // .workspace.projectDir // "", .cwd // "", .session_id // .sessionId // ""] | @tsv')"
# Last-resort: derive session_id from transcript_path basename if both
# field-name variants returned empty. CC always passes transcript_path,
# and the filename is `${SESSION_ID}.jsonl`.
if [ -z "$SESSION_ID" ]; then
  TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // .transcriptPath // ""')
  if [ -n "$TRANSCRIPT_PATH" ]; then
    SESSION_ID=$(basename "$TRANSCRIPT_PATH" .jsonl)
  fi
fi

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

# Write marker BEFORE polling, so the statusline has something to read even
# if CC kills this hook at the timeout. The Mira project's replay agent
# routinely takes minutes (large repo) — the SessionStart polling loop
# below would consistently exceed CC's 5s timeout, the hook would be
# cancelled, no marker would be written, and the user would see no boot
# indicator at all. Writing here closes that gap: even on timeout, the
# statusline shows ⏳pending instead of nothing, and the next
# UserPromptSubmit can self-heal once BOOT_CTX appears.
if [ -n "$SESSION_ID" ]; then
  if [ -f "$BOOT_CTX" ]; then
    EARLY_MARKER_STATE="loaded"
  elif replay_running; then
    EARLY_MARKER_STATE="pending"
  else
    EARLY_MARKER_STATE="none"
  fi
  printf '%s' "$EARLY_MARKER_STATE" > "$MARKER_FILE"
fi

CONTEXT=""

# Polling caps must stay under CC's hook timeouts (settings.json:
# SessionStart=5s, UserPromptSubmit=10s) — otherwise the hook gets killed
# mid-poll and the final marker/inject never happens. Mira's project
# repeatedly hit this: every boot-inject for the past 5 sessions was
# cancelled, leaving zero markers and zero injected context.
if [ "$EVENT" = "SessionStart" ] && [ ! -f "$BOOT_CTX" ] && replay_running; then
  # Capped at 4s to fit comfortably under the 5s SessionStart timeout.
  i=0
  while [ "$i" -lt 4 ]; do
    sleep 1
    i=$((i + 1))
    if [ -f "$BOOT_CTX" ]; then
      break
    fi
    replay_running || break
  done
fi

if [ "$EVENT" = "UserPromptSubmit" ] && [ ! -f "$BOOT_CTX" ] && replay_running; then
  # Capped at 9s to fit under the 10s UserPromptSubmit timeout. If replay
  # exceeds this window (large project, slow replay agent), the marker
  # stays "pending" and the next UserPromptSubmit retries — the loop
  # iterates per-prompt rather than blocking one prompt for minutes.
  i=0
  while [ "$i" -lt 9 ]; do
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
