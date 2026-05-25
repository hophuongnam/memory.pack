#!/bin/sh
# Memory.Pack Stop hook: append a per-turn cumulative-token sample to
# ~/.claude/statusline-token-rate.log. statusline-command.sh tails this log
# (last 16 per session) for the turn-rate sparkline.
#
# Race-tolerant: CC's docs explicitly disclaim transcript jsonl flush
# ordering vs hook execution. If the assistant entry for this turn isn't in
# the tail window yet, exit 0 silent — the next Stop catches up because
# we write CUMULATIVE counts, not deltas.
#
# Bilingual stdin: accepts both snake_case and camelCase field names
# (invariant #3; CC field names drift between releases).

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // .sessionId // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null)

[ -z "$session_id" ] && exit 0
[ -z "$transcript" ] && exit 0
[ -f "$transcript" ] || exit 0

usage=$(tail -n 50 "$transcript" 2>/dev/null \
  | jq -c 'select(.type=="assistant") | .message.usage' 2>/dev/null \
  | tail -n 1)
[ -z "$usage" ] && exit 0

cum=$(printf '%s' "$usage" | jq -r '
  (.input_tokens                // 0) +
  (.cache_creation_input_tokens // 0) +
  (.cache_read_input_tokens     // 0) +
  (.output_tokens               // 0)
' 2>/dev/null)
[ -z "$cum" ] && exit 0

mkdir -p "$HOME/.claude"
printf '%s %s %s\n' "$(date +%s)" "$session_id" "$cum" >> "$HOME/.claude/statusline-token-rate.log"
exit 0
