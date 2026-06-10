# shellcheck shell=bash
# Memory.Pack shared shell library. Sourced by hooks (via
# `. "$SCRIPT_DIR/_lib.sh"`); never executed as a hook itself, hence the
# leading-underscore name and no shebang / no +x.

# _mp_hash: read stdin, print the first 8 hex chars of its MD5 digest.
#
# Value-preserving, OS-independent replacement for the legacy expression
#   printf '%s' "$KEY" | md5 | head -c 8
# macOS `md5` prints the digest alone ("<hex>\n"); GNU `md5sum` prints
# "<hex>  -\n"; python3's hexdigest()[:8] prints the 8 hex chars alone.
# All three yield the SAME first 8 hex chars (MD5 is tool-independent), so
# the derived PROJECT_HASH is byte-identical across macOS / Linux / Windows
# — existing .boot-context-<hash> and .skip-replay-<hash> sentinels stay
# valid, and statusline-command.sh's independent derivation keeps matching.
#
# Branch ORDER is a latency choice, NOT a value choice (the hash is
# identical whichever tool computes it): md5sum/md5 are ~2ms and run first
# because _mp_hash sits on boot-inject.sh's pre-marker critical path, which
# was hand-tuned to beat the statusline race by tens of ms. python3 is the
# universal fallback (a hard install dependency; the ONLY hash tool on a
# bare Windows host, where neither md5sum nor md5 exists) and pays its
# ~50ms cold start only when no fast tool is present. statusline uses the
# same md5sum→md5→python3 ordering so the two derivations never diverge.
#
# Still fails LOUD (stderr + return 1) when NONE of the three exist rather
# than emitting an empty hash: a silent empty PROJECT_HASH would mis-scope
# every boot-context/sentinel filename — exactly the silent-amnesia class
# this shim exists to eliminate.
_mp_hash() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum | head -c 8
  elif command -v md5 >/dev/null 2>&1; then
    md5 | head -c 8
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import hashlib,sys;sys.stdout.write(hashlib.md5(sys.stdin.buffer.read()).hexdigest()[:8])'
  else
    echo "memory-pack: no md5sum, md5, or python3 for PROJECT_HASH derivation" >&2
    return 1
  fi
}

# _mp_resolve_project_key: derive PROJECT_KEY anchored to CC's authoritative
# per-session slug (= basename of dirname of transcript_path), not the live
# cwd. Walks up from $2 (best-guess starting dir, normally
# workspace.project_dir-or-cwd-or-$PWD) looking for the ancestor whose
# [/.] → - slugification equals CC's slug. That ancestor is the project
# root CC chose at session launch; using it keeps every Memory.Pack hash /
# slug / MEMORY_DIR / boot-context filename aligned with what CC writes the
# JSONL under.
#
# Why this exists: PROJECT_KEY="${PROJECT_DIR:-${CWD:-$PWD}}" was the prior
# scheme. workspace.project_dir is empty in some CC versions (proven in
# active use — boot-context-947df9d4 in Pre.Audit, Green.World subfolder
# hash, holding content that belongs in Pre.Audit's e5edaabc store); the
# fallback to .cwd then follows the user's mid-session `cd`. Result:
# session-end writes boot-context under the subfolder hash, the next
# session at the project root reads under the parent hash, sees nothing,
# silent amnesia. This resolver is the writer↔CC path-parity defense and
# is the source-of-truth for both session-end.sh and boot-inject.sh (and
# mirrored in statusline-command.sh for invariant #2).
#
# Args:
#   $1 = transcript_path from hook stdin (may be empty)
#   $2 = fallback project key (e.g. "${PROJECT_DIR:-${CWD:-$PWD}}")
# Output: the resolved absolute project root, or $2 unchanged if the
# transcript anchor is missing or no ancestor of $2 matches.
_mp_resolve_project_key() {
  _mp_transcript="$1"
  _mp_fallback="$2"
  if [ -z "$_mp_transcript" ] || [ -z "$_mp_fallback" ]; then
    printf '%s' "$_mp_fallback"
    return 0
  fi
  _mp_cc_slug=$(basename "$(dirname "$_mp_transcript")")
  if [ -z "$_mp_cc_slug" ]; then
    printf '%s' "$_mp_fallback"
    return 0
  fi
  _mp_dir="$_mp_fallback"
  while [ -n "$_mp_dir" ] && [ "$_mp_dir" != "/" ] && [ "$_mp_dir" != "." ]; do
    _mp_candidate=$(printf '%s' "$_mp_dir" | sed 's|[/.]|-|g')
    if [ "$_mp_candidate" = "$_mp_cc_slug" ]; then
      printf '%s' "$_mp_dir"
      return 0
    fi
    _mp_dir=$(dirname "$_mp_dir")
  done
  printf '%s' "$_mp_fallback"
}

# _mp_real_user_turns: count REAL user turns in a CC transcript jsonl,
# printed as a bare integer (0 on missing/empty/unreadable transcript).
#
# "type":"user" entries are NOT user turns in general: tool_results come
# back as user-type entries with array content, and isMeta:true entries are
# CC/engine bookkeeping (system-reminders, auto-save-stop feedback) injected
# MID-turn — a real 594-line transcript held 153 user-type entries but only
# 2 real prompts. A REAL turn is: type=="user", not isMeta, content either
# a string without <command-message> (slash-command invocations are not
# exchanges) or an array with no tool_result block. This mirrors
# log-token-rate.sh's mutation-pinned is_user_prompt semantics
# (reference_cc_transcript_isMeta_mid_turn.md); keep the two in sync.
#
# Used by session-end.sh (trivial-session replay skip) and
# auto-save-stop.sh (SAVE_INTERVAL checkpoint counting). The per-line
# `fromjson? // empty` pass drops the malformed tail line CC can leave
# mid-write instead of crashing the count. _mp_conversation_chars below
# shares the same user-entry semantics — keep them aligned.
_mp_real_user_turns() {
  _mp_t="$1"
  if [ -z "$_mp_t" ] || [ ! -f "$_mp_t" ]; then
    printf '0'
    return 0
  fi
  _mp_n=$(jq -cR 'fromjson? // empty' "$_mp_t" 2>/dev/null | jq -sr '
    [ .[] | select(
        .type == "user"
        and ((.isMeta // false) | not)
        and (
          (.message.content | type) as $ct |
          if   $ct == "string" then (.message.content | contains("<command-message>") | not)
          elif $ct == "array"  then ([.message.content[].type] | index("tool_result")) == null
          else false end
        )
      ) ] | length' 2>/dev/null)
  case "$_mp_n" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$_mp_n" ;;
  esac
}

# _mp_conversation_chars: total chars of user/assistant conversation text a
# replay agent would actually see, printed as a bare integer (0 on
# missing/empty/unreadable transcript).
#
# Mirrors _lib.mjs extractConversation (which builds the replay prompt): a
# user entry counts only when NOT isMeta and its content is a string or a
# tool_result-free array (text blocks joined with \n); an assistant entry
# counts its FIRST text block only. Slight undercount vs the .mjs output
# (no "USER: "/"ASSISTANT: " prefixes, no inter-entry newlines) — fine for
# thresholding, never use for equality. Keep in sync with
# extractConversation (_lib.mjs), _mp_real_user_turns above, and
# log-token-rate.sh's is_user_prompt.
#
# Used by session-end.sh's trivial-skip gate: a ≤5-turn session whose
# conversation is big is a single-prompt autonomous/discussion session,
# not a trivial one — turn count alone under-measures it.
_mp_conversation_chars() {
  _mp_t="$1"
  if [ -z "$_mp_t" ] || [ ! -f "$_mp_t" ]; then
    printf '0'
    return 0
  fi
  _mp_n=$(jq -cR 'fromjson? // empty' "$_mp_t" 2>/dev/null | jq -sr '
    [ .[]
      | if .type == "user" and ((.isMeta // false) | not) then
          (.message.content | type) as $ct |
          if   $ct == "string" then (.message.content | length)
          elif $ct == "array"  then
            (if ([.message.content[].type] | index("tool_result")) == null
             then ([.message.content[] | select(.type == "text" and ((.text // "") != "")) | .text] | join("\n") | length)
             else 0 end)
          else 0 end
        elif .type == "assistant" then
          ([.message.content[]? | select(.type == "text" and ((.text // "") != "")) | .text] | first // "" | length)
        else 0 end
    ] | add // 0' 2>/dev/null)
  case "$_mp_n" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$_mp_n" ;;
  esac
}

# _mp_have_nerdfont: returns 0 if a Nerd Font is available for the statusline
# icon set, 1 otherwise. Env override MEMORY_PACK_NERDFONT={1,true,yes} forces
# yes, MEMORY_PACK_NERDFONT={0,false,no} forces no, empty/unset falls through
# to `fc-list :family | grep -qi 'nerd'`. Used by hooks/statusline-icons.sh to
# pick the glyph table. fc-list is part of fontconfig (Linux: usually present;
# macOS: present via Homebrew or system Cairo); absent → returns 1 (Unicode
# fallback wins). Never prints to stdout.
_mp_have_nerdfont() {
  case "${MEMORY_PACK_NERDFONT:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  command -v fc-list >/dev/null 2>&1 || return 1
  fc-list :family 2>/dev/null | grep -qi 'nerd'
}
