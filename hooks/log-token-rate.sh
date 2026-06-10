#!/bin/sh
# Memory.Pack Stop hook: append per-turn cumulative-token samples to
# ~/.claude/statusline-token-rate.log. statusline-command.sh tails this log
# (last 16 per session) for the turn-rate sparkline (line 3).
#
# Backfill semantics: scan the whole transcript for "turn boundaries" and
# emit one log line per boundary whose cumulative-tokens count exceeds the
# max already logged for this session. On a /resume'd session this catches
# up all prior turns on the first Stop, so line 3 lights up immediately
# instead of after the second Stop. Subsequent Stops are no-ops until new
# turns happen (idempotent via the monotonic cum > last-logged filter —
# session cumulative tokens are monotonic by construction).
#
# A "turn boundary" = an assistant entry with .message.usage whose immediate
# next user-or-assistant entry is a REAL user-prompt (string content, OR
# array content with no tool_result blocks), or end-of-file. The pre-filter
# DROPS isMeta:true user entries — CC's own bookkeeping plus Memory.Pack's
# auto-save-stop feedback both appear as isMeta:true user-with-text mid-
# turn, and treating them as boundaries would emit spurious intermediate
# cumulatives (verified against real transcripts 2026-05-26).
#
# Race-tolerant per CC docs (no flush guarantee for transcript jsonl vs
# Stop): if usage isn't visible yet, exit 0 silently — next Stop catches up.
# Bilingual stdin: snake_case + camelCase (invariant #3; CC field names
# drift between releases).

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id   // .sessionId      // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null)

[ -z "$session_id" ] && exit 0
[ -z "$transcript" ] && exit 0
[ -f "$transcript" ] || exit 0

LOG="$HOME/.claude/statusline-token-rate.log"

# Highest cumulative already logged for this session (0 if none / no log).
last_cum=0
if [ -f "$LOG" ]; then
  last_cum=$(awk -v sid="$session_id" '$2 == sid && $3+0 > m+0 { m = $3+0 } END { print m+0 }' "$LOG")
fi

# Walk transcript: per-line parse (skip malformed via fromjson?), pre-filter
# to assistant + non-isMeta user entries, then for each assistant-with-usage
# emit cum_tokens iff the next entry in the filtered stream is a user-prompt
# (string OR array-without-tool_result) or end-of-file.
samples=$(
  jq -cR 'fromjson? // empty' "$transcript" 2>/dev/null \
  | jq -sr --argjson last_cum "$last_cum" '
      def cum_tokens:
        (.message.usage.input_tokens                // 0) +
        (.message.usage.cache_creation_input_tokens // 0) +
        (.message.usage.cache_read_input_tokens     // 0) +
        (.message.usage.output_tokens               // 0);
      def is_user_prompt:
        .type == "user" and (
          (.message.content | type) as $ct |
          if   $ct == "string" then true
          elif $ct == "array"  then ([.message.content[].type] | index("tool_result")) == null
          else false end
        );
      [ .[] | select(
          .type == "assistant" or
          (.type == "user" and ((.isMeta // false) | not))
      ) ] as $all |
      [ $all | to_entries[] |
        select(
          .value.type == "assistant" and
          (.value.message.usage // null) != null and
          (.value | cum_tokens) > 0 and
          (
            ($all[.key + 1] // null) as $next |
            $next == null or ($next | is_user_prompt)
          )
        ) | .value | cum_tokens
      ] |
      # Monotonic-cum filter: only emit boundaries strictly above last_cum.
      reduce .[] as $c ({prev: $last_cum, out: []};
        if $c > .prev then {prev: $c, out: (.out + [$c])} else . end
      ) |
      .out[]
  ' 2>/dev/null
)

[ -z "$samples" ] && exit 0

mkdir -p "$HOME/.claude"
ts=$(date +%s)
printf '%s\n' "$samples" | while IFS= read -r cum; do
  [ -z "$cum" ] && continue
  printf '%s %s %s\n' "$ts" "$session_id" "$cum" >> "$LOG"
done

# Rotate past 4000 lines down to the newest 2000. The statusline only ever
# tails the last 16 per session, so the tail is all signal; without this
# the log appended one line per turn forever. Runs AFTER the append so the
# samples just written are inside the kept tail. tail+mv can drop a
# concurrent Stop's sample — display log only, last-writer-wins is fine.
lines=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
if [ -n "$lines" ] && [ "$lines" -gt 4000 ] 2>/dev/null; then
  tail -n 2000 "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG"
  rm -f "$LOG.tmp.$$" 2>/dev/null
fi
exit 0
