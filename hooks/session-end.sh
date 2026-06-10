#!/bin/bash
# SessionEnd hook: launch replay of ending session.
# Replay runs detached via nohup; boot context written to .boot-context
# for the boot-inject hook to inject on the next session's first turn.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh" || { echo "memory-pack: cannot source $SCRIPT_DIR/_lib.sh" >&2; exit 1; }

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
# into project B's next session. PROJECT_KEY is resolved against CC's
# per-session slug (basename of dirname of transcript_path) so a mid-session
# `cd` into a subfolder cannot retarget the hash — that is the silent-amnesia
# class the resolver in _lib.sh defends against.
PROJECT_KEY=$(_mp_resolve_project_key "$TRANSCRIPT" "${PROJECT_DIR:-${CWD:-$PWD}}")
PROJECT_HASH=$(printf '%s' "$PROJECT_KEY" | _mp_hash)
PROJECT_NAME=$(basename "$PROJECT_KEY" 2>/dev/null)
[ -z "$PROJECT_NAME" ] && PROJECT_NAME="unknown"
BOOT_CTX="$SCRIPT_DIR/.boot-context-${PROJECT_HASH}"
PID_FILE="$SCRIPT_DIR/.replay-pid-${PROJECT_HASH}"
ERR_MARKER="$SCRIPT_DIR/.replay-error-${PROJECT_HASH}"
# Per-project stderr log (NOT a fixed /tmp path: concurrent replays from
# different projects clobbered a shared /tmp/replay-error.log and the
# synthetic failure boot-context could embed the WRONG project's error).
# Name sits inside the existing .replay-* gitignore/install excludes.
ERR_LOG="$SCRIPT_DIR/.replay-error-${PROJECT_HASH}.log"

# Carry-forward: when this session's replay is skipped — either by the
# user opt-out sentinel or the trivial-session auto-skip below — the next
# session would otherwise load as "No boot context available" because
# boot-inject.sh already consumed this session's incoming boot context at
# startup and nothing replaces it. That silently breaks the memory chain
# at every skip. boot-inject.sh snapshots each consumed boot context to
# .boot-context-last-${PROJECT_HASH}; resurrect it here (with a header
# marking it as carried over) so continuity survives the skip.
carry_forward() {
  reason="$1"
  # Never clobber a fresh boot context (would only exist if boot-inject
  # failed to consume it this session — leave it for the next session).
  [ -f "$BOOT_CTX" ] && return 0
  LAST_BOOT="$SCRIPT_DIR/.boot-context-last-${PROJECT_HASH}"
  [ -f "$LAST_BOOT" ] || return 0
  # Strip a prior carry-forward header (+ its blank line) before
  # re-wrapping, so a run of consecutive skips keeps exactly one header
  # instead of stacking them unboundedly.
  {
    printf '[Carry-forward: %s. The summary below is from a prior session, not the one that just ended.]\n\n' "$reason"
    awk 'NR==1 && /^\[Carry-forward:/ {h=1; next} NR==2 && h && /^$/ {next} {print}' "$LAST_BOOT"
  } > "$BOOT_CTX"
}

# Skip-replay opt-out: one-shot sentinel set during the session when the
# user asked to skip this session's replay. See boot-inject.sh's static
# "Skip-replay protocol" block for the trigger phrases and consumption
# contract. Consumed here (rm) so the next session replays normally
# unless the user opts out again.
SKIP_SENTINEL="$SCRIPT_DIR/.skip-replay-${PROJECT_HASH}"
if [ -f "$SKIP_SENTINEL" ]; then
  rm -f "$SKIP_SENTINEL"
  carry_forward "replay skipped by user request"
  osascript -e "display notification \"Replay skipped\" with title \"Claude Code · $PROJECT_NAME\"" >/dev/null 2>&1 || true
  exit 0
fi

# Skip trivial sessions (≤5 REAL user turns), but still carry the prior
# boot context forward so the next real session isn't amnesiac about the
# last meaningful one. _mp_real_user_turns excludes tool_results / isMeta /
# slash-command entries — the old grep -c '"type":"user"' counted every
# tool_result, so any session with ≥4 tool calls cleared the bar and got a
# (paid) replay it didn't deserve.
TURNS=$(_mp_real_user_turns "$TRANSCRIPT")
if [ "$TURNS" -le 5 ]; then
  carry_forward "session had $TURNS user turn(s) — too short to replay"
  exit 0
fi

# Resolve replay script location (follow symlinks to find co-located replay.mjs)
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
REAL_DIR="$(cd "$SCRIPT_DIR" && cd "$(dirname "$(readlink "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")")" && pwd)"
REPLAY="$REAL_DIR/replay.mjs"
[ ! -f "$REPLAY" ] && REPLAY="$SCRIPT_DIR/replay.mjs"

# Clean stale boot context, tmp files (legacy .tmp and the .tmp.<pid>
# family), PID file, error marker, and error log for this project. The
# error marker/log are only meaningful between runs — the new run either
# clears them (success / benign no-op) or re-writes them (failure).
rm -f "$BOOT_CTX" "$BOOT_CTX".tmp* "$PID_FILE" "$ERR_MARKER" "$ERR_LOG"

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
# format so boot-inject.sh treats it uniformly. The SUMMARY embeds the tail
# of the per-project error log so the failure is self-reporting.
#
# Every dynamic value crosses into the detached shell via `env` — the body
# is one STATIC single-quoted script with zero interpolation. The previous
# interpolated form was a parse error for any project path containing a
# quote (e.g. "Nam's Proj"): the detached sh died before `echo $$`, so no
# replay, no PID file, no error marker — the silent-amnesia class. The
# notification title is additionally stripped of `"` and `\` because it
# lands inside an AppleScript double-quoted string literal.
MP_NOTIFY_TITLE="Claude Code · $(printf '%s' "$PROJECT_NAME" | tr -d '"\\')"
# Stdout goes to a per-process tmp ($$ of the detached sh) so two
# concurrent same-project replays can't interleave one tmp file; the final
# mv is last-writer-wins, atomic either way.
nohup env \
  MP_PID_FILE="$PID_FILE" \
  MP_BOOT_CTX="$BOOT_CTX" \
  MP_ERR_MARKER="$ERR_MARKER" \
  MP_ERR_LOG="$ERR_LOG" \
  MP_REPLAY="$REPLAY" \
  MP_SESSION_ID="$SESSION_ID" \
  MP_PROJECT_KEY="$PROJECT_KEY" \
  MP_NOTIFY_TITLE="$MP_NOTIFY_TITLE" \
  sh -c '
    echo $$ > "$MP_PID_FILE"
    osascript -e "display notification \"Replay started\" with title \"$MP_NOTIFY_TITLE\"" >/dev/null 2>&1 || true
    MP_TMP="$MP_BOOT_CTX.tmp.$$"
    node "$MP_REPLAY" "$MP_SESSION_ID" "$MP_PROJECT_KEY" > "$MP_TMP" 2> "$MP_ERR_LOG"
    STATUS=$?
    if [ "$STATUS" -eq 0 ] && [ -s "$MP_TMP" ]; then
      mv "$MP_TMP" "$MP_BOOT_CTX"
      rm -f "$MP_ERR_MARKER" "$MP_ERR_LOG"
      osascript -e "display notification \"Replay finished\" with title \"$MP_NOTIFY_TITLE\"" >/dev/null 2>&1 || true
    elif [ "$STATUS" -eq 2 ]; then
      rm -f "$MP_TMP" "$MP_ERR_MARKER" "$MP_ERR_LOG"
    else
      rm -f "$MP_TMP"
      ERR_TAIL=$(tail -c 400 "$MP_ERR_LOG" 2>/dev/null | tr "\n" " " | sed "s/  */ /g; s/^ *//; s/ *\$//")
      [ -z "$ERR_TAIL" ] && ERR_TAIL="(no stderr captured; exit $STATUS with empty stdout)"
      printf "TITLE: Replay failed for prior session\nSUMMARY: replay.mjs exited %s. stderr tail: %s\nTODO: investigate %s and Memory.Pack/hooks/replay.mjs — the prior session was not summarized\nDECISIONS: none\n" "$STATUS" "$ERR_TAIL" "$MP_ERR_LOG" > "$MP_BOOT_CTX"
      printf "exit=%s\nreason=%s\n" "$STATUS" "$ERR_TAIL" > "$MP_ERR_MARKER"
      osascript -e "display notification \"Replay failed — see $MP_ERR_LOG\" with title \"$MP_NOTIFY_TITLE\"" >/dev/null 2>&1 || true
    fi
    rm -f "$MP_PID_FILE"
  ' </dev/null >/dev/null 2>&1 &
disown
