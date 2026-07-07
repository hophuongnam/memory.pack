#!/bin/bash
# UserPromptSubmit hook — auto-search the auto-memory FTS5 index for
# prompt-relevant hits and inject them as additionalContext.
#
# Why this exists: the manual /memory-search skill (and the search CLI)
# are opt-in — they depend on Claude remembering to invoke them. The
# whole point of choosing Tier 1 (FTS5 index + auto-trigger) over Tier 0
# (passive pointer in MEMORY.md) was to solve the trigger problem. The
# index-only side of that was built first; this script is the trigger.
#
# Output: a `## Memory hits` block listing up to OUTPUT_LIMIT (default 3)
# hits whose BM25 rank clears MEMORY_SEARCH_THRESHOLD (default -8.0).
# BM25 is negative — lower is better — so the threshold is a max value.
#
# Skips silently when:
#   - prompt is empty, shorter than MIN_LEN (default 10), or a slash command
#   - no usable tokens survive stopword/length/numeric filtering
#   - no hits clear the threshold
#   - search.db is missing (e.g. before first indexer run)
#
# Budget: ~30ms typical end-to-end. Bash + jq + sqlite3 deliberately —
# Python's ~50ms cold start would dominate the budget on every prompt.
# Tokens are pre-sanitized to [a-z0-9_]+ so the SQL interpolation below
# cannot inject quotes or FTS5 syntax.

INPUT=$(cat)

# .prompt is the documented field; .userPrompt is the camelCase drift
# fallback (see reference_cc_hook_input_fields.md).
PROMPT=$(echo "$INPUT" | jq -r '.prompt // .userPrompt // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // .transcriptPath // empty')

MIN_LEN="${MEMORY_SEARCH_MIN_LEN:-10}"
THRESHOLD="${MEMORY_SEARCH_THRESHOLD:--8.0}"
SQL_LIMIT="${MEMORY_SEARCH_SQL_LIMIT:-5}"
OUTPUT_LIMIT="${MEMORY_SEARCH_OUTPUT_LIMIT:-3}"
DB="${MEMORY_SEARCH_DB:-${MEMORY_PACK_HOME:-$HOME/.memory-pack}/index/search.db}"
TRANSCRIPT_TAIL_LINES="${MEMORY_SEARCH_TRANSCRIPT_LINES:-50}"
TRANSCRIPT_TAIL_BYTES="${MEMORY_SEARCH_TRANSCRIPT_BYTES:-4096}"

# Skip outright when there's no useful prompt OR no index. The MIN_LEN
# guard is intentionally weaker now: short follow-ups like "do that" used
# to be skipped, but the transcript-aware tokenization below means a
# 6-char prompt + recent context can still produce useful tokens. Keep a
# small floor (3) just to drop accidental keystrokes.
[ -z "$PROMPT" ] && exit 0
[ "${#PROMPT}" -lt 3 ] && exit 0
case "$PROMPT" in
  /*) exit 0 ;;
esac
[ -f "$DB" ] || exit 0

# Pull text+thinking content from the last N transcript turns so follow-up
# prompts ("fix that", "any other ideas?") inherit topic keywords from
# recent context. Bounded by line-tail then byte-tail to cap latency and
# token noise. Falls back to empty if the transcript is missing (first
# UserPromptSubmit of a session) or jq fails — the prompt-only path then
# applies the original MIN_LEN floor below.
TRANSCRIPT_TEXT=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # isMeta filter: the engine's OWN injected blocks (memory hits, boot
  # context, auto-save feedback) arrive as isMeta:true user entries —
  # blending them feeds our own output back into the query tokens on
  # every follow-up prompt (a search feedback loop).
  TRANSCRIPT_TEXT=$(tail -n "$TRANSCRIPT_TAIL_LINES" "$TRANSCRIPT" 2>/dev/null \
    | jq -r 'select(.type == "user" or .type == "assistant")
             | select((.isMeta // false) | not)
             | .message.content as $c
             | if ($c | type) == "string" then $c
               elif ($c | type) == "array" then
                 ($c | map(
                   if .type == "text" then .text
                   elif .type == "thinking" then .thinking
                   else empty end
                 ) | join(" "))
               else "" end' 2>/dev/null \
    | tail -c "$TRANSCRIPT_TAIL_BYTES")
fi

# When there's no transcript context, require the original MIN_LEN floor
# to avoid running search on accidental short prompts ("ok", "yes").
if [ -z "$TRANSCRIPT_TEXT" ] && [ "${#PROMPT}" -lt "$MIN_LEN" ]; then
  exit 0
fi

# Tokenize the prompt and emit a ready-to-use FTS5 OR query in one pass.
# Tokens are filtered to [a-z0-9_]+, length >= 3, not a stopword, not
# pure-digit, dedup'd, capped at MAX_TOKENS. Output is the tokens joined
# by " OR " — safe to interpolate into SQL because the per-token regex
# guarantees no SQL/FTS5 metacharacters survive. Done in awk so we don't
# depend on sed's `\+` behavior, which differs between GNU and BSD seds.
MAX_TOKENS="${MEMORY_SEARCH_MAX_TOKENS:-12}"
# Prompt-dominance threshold: if the literal prompt yields at least this
# many distinct content tokens, treat it as "meaty enough on its own" and
# skip the transcript blend entirely. Transcript is fallback context for
# sparse prompts, not a tag-along for every query.
DOMINANCE="${MEMORY_SEARCH_PROMPT_DOMINANCE:-5}"

# Shared tokenizer. Reads stdin, emits up to $1 distinct content tokens
# joined as " OR " on stdout. Filters: lowercase, [a-z0-9_]+ only,
# length>=3, not a stopword, not pure-digit, deduplicated. Done in awk so
# we don't depend on sed's `\+` behavior (BSD/GNU split — see
# feedback_bsd_sed_plus_quantifier_silent_skip.md).
tokenize() {
  awk -v max="$1" '
    BEGIN {
      split("the and for are was were but not have has had this that with from into onto upon via how what why when where which who does did doing done just can could should would will may might must you your yours our any all some one two three use using used get got make made want need like see look know think work works working new old good bad right wrong sure yes yeah ok okay please thanks thank also only even very much more most less least than then now here there over under out off its way them they their these those been being able lets let going gets needs makes seems still ever ago far near soon already maybe perhaps actually really basically essentially literally totally fully truly etc such same other another about above below before after during without within between among through against around inside outside across along behind beside beyond despite toward upon", sw, " ");
      for (i in sw) stop[sw[i]] = 1;
      count = 0;
      out = "";
    }
    {
      s = tolower($0);
      gsub(/[^a-z0-9_]+/, " ", s);
      n = split(s, words, " ");
      for (i = 1; i <= n; i++) {
        w = words[i];
        if (length(w) < 3) continue;
        if (w in stop) continue;
        if (w ~ /^[0-9]+$/) continue;
        if (w in seen) continue;
        seen[w] = 1;
        if (out == "") out = w; else out = out " OR " w;
        count++;
        if (count >= max) { exit }
      }
    }
    END { if (out != "") print out }
  '
}

# Pass 1: tokenize the prompt alone.
PROMPT_QUERY=$(printf '%s\n' "$PROMPT" | tokenize "$MAX_TOKENS")
PROMPT_TOKENS=$(printf '%s' "$PROMPT_QUERY" | awk -F' OR ' 'BEGIN{n=0} {n=NF} END{print n}')

# Pass 2: blend transcript only if the prompt is sparse AND we have one.
if [ "$PROMPT_TOKENS" -ge "$DOMINANCE" ] || [ -z "$TRANSCRIPT_TEXT" ]; then
  QUERY="$PROMPT_QUERY"
else
  QUERY=$(printf '%s\n%s\n' "$PROMPT" "$TRANSCRIPT_TEXT" | tokenize "$MAX_TOKENS")
fi

[ -z "$QUERY" ] && exit 0

# TOKENS = space-separated form for downstream coverage check.
TOKENS=$(printf '%s' "$QUERY" | awk -F' OR ' '{for(i=1;i<=NF;i++){if(i>1) printf " "; printf "%s", $i}}')
TOTAL_TOKENS=$(printf '%s' "$TOKENS" | awk '{print NF}')

# Coverage filter: drop hits that match fewer than MIN_COVERAGE_PCT of the
# query tokens (default 30%). Counters the BM25-OR coverage artifact —
# without this, a short doc that incidentally mentions every token once
# can outrank a focused doc that matches a few terms heavily (see
# feedback_fts5_bm25_or_query_coverage_dominates.md). Disabled when
# TOTAL_TOKENS<3 (the percentage is meaningless for tiny queries).
MIN_COVERAGE_PCT="${MEMORY_SEARCH_MIN_COVERAGE_PCT:-30}"
if [ "$TOTAL_TOKENS" -lt 3 ]; then
  MIN_MATCHES=1
else
  MIN_MATCHES=$(awk -v t="$TOTAL_TOKENS" -v p="$MIN_COVERAGE_PCT" 'BEGIN{n=int((t*p+99)/100); if(n<1)n=1; print n}')
fi

# Top SQL_LIMIT hits ranked by BM25. Pipe-separated. We fetch a body
# excerpt (substr 1..1500) so the coverage filter has enough text to
# substring-match query tokens. Description and body may contain pipes
# (rare) — the awk filter below uses fixed FS expectations and treats
# the LAST trailing fields as body to absorb stray pipes safely.
SQL_LIMIT_FETCH=$((SQL_LIMIT * 3))
HITS=$(sqlite3 -separator $'\x01' "$DB" <<SQL 2>/dev/null
SELECT
  printf('%.2f', bm25(memories)),
  status,
  type,
  project,
  abs_path,
  replace(replace(COALESCE(name, ''), char(10), ' '), char(13), ' '),
  replace(replace(COALESCE(description, ''), char(10), ' '), char(13), ' '),
  substr(replace(replace(COALESCE(body, ''), char(10), ' '), char(13), ' '), 1, 1500)
FROM memories
WHERE memories MATCH '$QUERY'
ORDER BY bm25(memories)
LIMIT $SQL_LIMIT_FETCH;
SQL
)
[ -z "$HITS" ] && exit 0

# Threshold + coverage filter + output cap. BM25 is negative; smaller
# (more negative) = better. We want rank <= THRESHOLD (e.g. -8.0) AND
# matches >= MIN_MATCHES (coverage filter).
# Project display prefix: strip the slugified $HOME so store slugs read as
# project names on ANY host (the old hardcoded -Users-namhp-Resilio-Sync-
# prefix only ever matched the original machine).
HOME_SLUG=$(printf '%s' "$HOME" | sed 's|[/.]|-|g')

BODY=$(printf '%s\n' "$HITS" | awk -F$'\x01' \
  -v t="$THRESHOLD" -v cap="$OUTPUT_LIMIT" \
  -v home_slug="$HOME_SLUG" \
  -v min_match="$MIN_MATCHES" -v tokens="$TOKENS" '
BEGIN {
  n_tok = split(tokens, tok_arr, " ");
}
NF >= 8 && ($1 + 0.0) <= (t + 0.0) {
  rank = $1; status = $2; type = $3; project = $4;
  path = $5; name = $6; desc = $7; body = $8;
  for (i = 9; i <= NF; i++) body = body "\x01" $i;

  # Coverage check: how many distinct query tokens appear (case-insensitive
  # substring) in the searchable surface of this hit?
  haystack = tolower(name " " desc " " body);
  matches = 0;
  for (i = 1; i <= n_tok; i++) {
    if (tok_arr[i] != "" && index(haystack, tok_arr[i]) > 0) matches++;
  }
  if (matches < (min_match + 0)) next;

  desc_short = desc;
  if (length(desc_short) > 160) desc_short = substr(desc_short, 1, 160) "…";
  short_project = project;
  # index/substr, not a dynamic regex: the slug may contain metacharacters.
  if (home_slug != "" && index(short_project, home_slug "-") == 1)
    short_project = substr(short_project, length(home_slug) + 2);
  printf "- [bm25=%s · cov=%d/%d · %s · %s · %s] %s\n  %s\n",
    rank, matches, n_tok, status, type, short_project, path, desc_short;
  shown++;
  if (shown >= cap) exit;
}
')

[ -z "$BODY" ] && exit 0

CONTEXT="## Memory hits (auto-search by prompt keywords)
The auto-memory FTS5 index matched these against the current prompt's content tokens. These are hints — read them only if they actually inform the task. They are unverified prior observations, not live state: verify before asserting any hit's content as fact. BM25 scores are negative; closer to zero = weaker match.

$BODY"

jq -n --arg ctx "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'

exit 0
