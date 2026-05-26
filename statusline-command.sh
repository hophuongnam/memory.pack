#!/bin/sh
# Claude Code status line — width-adaptive 3-line display.
# Line 1: dir + model pill + git + memory/boot/skip overlay
# Line 2: ctx + 5h + 7d bars
# Line 3: turn-rate sparkline (full + medium modes; narrow drops it)
#
# All usage data comes from Claude Code stdin (see
# https://code.claude.com/docs/en/statusline). rate_limits is absent until
# the first API response of a session, so the 5h/7d segments drop silently
# on the very first render.

input=$(cat)

# --- Stdin fields (session-specific) ---
project_dir=$(echo "$input"   | jq -r '.workspace.project_dir                       // .workspace.projectDir                        // empty')
dir=$(basename "$project_dir")
model=$(echo "$input"         | jq -r '.model.display_name                          // .model.displayName                           // empty')
ctx=$(echo "$input"           | jq -r '.context_window.used_percentage              // .contextWindow.usedPercentage                // empty')
transcript=$(echo "$input"    | jq -r '.transcript_path                             // .transcriptPath                              // empty')
session_id=$(echo "$input"    | jq -r '.session_id                                  // .sessionId                                   // empty')
five_h=$(echo "$input"        | jq -r '.rate_limits.five_hour.used_percentage       // .rateLimits.fiveHour.usedPercentage           // empty')
five_h_reset=$(echo "$input"  | jq -r '.rate_limits.five_hour.resets_at             // .rateLimits.fiveHour.resetsAt                 // empty')
seven_d=$(echo "$input"       | jq -r '.rate_limits.seven_day.used_percentage       // .rateLimits.sevenDay.usedPercentage           // empty')
seven_d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at             // .rateLimits.sevenDay.resetsAt                 // empty')

# --- Vibe coding method ---
vibe=""
if [ -n "$project_dir" ] && [ -f "$project_dir/vibeCodingMethod" ]; then
    vibe=$(cat "$project_dir/vibeCodingMethod" | tr -d '\n')
fi

# Project-hash helper — value-identical to Memory.Pack/hooks/_lib.sh
# `_mp_hash` (MD5 is tool-independent: the first 8 hex chars are the same
# whichever tool computes them, so the .skip-replay-<hash> sentinel name
# never diverges from the hooks' derivation). The legacy inline `md5` was
# macOS-only and silently produced an EMPTY hash on Linux, leaving the
# ⏭skip-replay indicator permanently dead there. Order md5sum→md5→python3
# mirrors _mp_hash (fast tools first; python3 is the universal fallback —
# the only one on a bare Windows host). No loud-fail branch on purpose: an
# unresolved hash here just hides one statusline glyph (non-catastrophic),
# unlike _mp_hash where an empty PROJECT_HASH causes silent amnesia.
mp_proj_hash() {
    if command -v md5sum >/dev/null 2>&1; then md5sum | head -c 8
    elif command -v md5 >/dev/null 2>&1; then md5 | head -c 8
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import hashlib,sys;sys.stdout.write(hashlib.md5(sys.stdin.buffer.read()).hexdigest()[:8])'
    fi
}

# Mirror of hooks/_lib.sh _mp_resolve_project_key — invariant #2 parity:
# the writers (boot-inject.sh / session-end.sh) now anchor PROJECT_KEY to
# CC's per-session slug (= basename of dirname of transcript_path) by
# walking up from the best-guess dir to the ancestor whose [/.] → -
# slugification equals CC's slug. Statusline MUST do the same or
# .skip-replay-<hash> targets the wrong sentinel on every session whose
# workspace.project_dir is empty or whose hooks resolved to a parent the
# stdin `project_dir` field misses. Same self-locating, OS-portable
# behavior as the helper in _lib.sh; not sourced because this script is
# /bin/sh and lives outside hooks/.
mp_resolve_project_key() {
    _tp="$1"
    _fb="$2"
    if [ -z "$_tp" ] || [ -z "$_fb" ]; then printf '%s' "$_fb"; return; fi
    _slug=$(basename "$(dirname "$_tp")")
    [ -z "$_slug" ] && { printf '%s' "$_fb"; return; }
    _d="$_fb"
    while [ -n "$_d" ] && [ "$_d" != "/" ] && [ "$_d" != "." ]; do
        if [ "$(printf '%s' "$_d" | sed 's|[/.]|-|g')" = "$_slug" ]; then
            printf '%s' "$_d"; return
        fi
        _d=$(dirname "$_d")
    done
    printf '%s' "$_fb"
}

# Format reset epoch (seconds) to a short relative countdown.
format_reset() {
    reset_epoch="$1"
    [ -z "$reset_epoch" ] && return
    diff=$(( reset_epoch - $(date +%s) ))
    if [ "$diff" -le 0 ]; then
        printf "now"
    elif [ "$diff" -lt 3600 ]; then
        printf "%dm" $(( diff / 60 ))
    elif [ "$diff" -lt 86400 ]; then
        printf "%dh%dm" $(( diff / 3600 )) $(( (diff % 3600) / 60 ))
    else
        printf "%dd%dh" $(( diff / 86400 )) $(( (diff % 86400) / 3600 ))
    fi
}

# --- Continuity system status ---
HOOK_STATE_DIR="$HOME/.claude/hook_state"
MEMORY_BASE="$HOME/.claude/projects"

# Resolve the hooks dir the SAME way the writers locate themselves, so the
# .boot-marker-<id> / .skip-replay-<hash> this script READS are the exact
# files boot-inject.sh:47,222 / session-end.sh:65,97 WRITE. Those write to
# $SCRIPT_DIR = abs dirname of the hook script. This script sits beside
# hooks/ and is invoked through the ~/.claude/statusline-command.sh
# symlink, so follow ONE symlink hop and append /hooks. Bare
# `readlink ... || echo` + cd/pwd is the engine's proven BSD-safe idiom
# (session-end.sh:86-87) — NOT GNU-only `readlink -f`, which is absent on
# BSD/macOS. Self-location, NOT $MEMORY_PACK_HOME: the writers never
# consult $MEMORY_PACK_HOME for $SCRIPT_DIR, so mirroring their derivation
# is what keeps reader and writer paths from silently diverging
# (statusline-parity, invariant #2). The legacy hardcoded
# $HOME/Resilio.Sync/Memory.Pack/hooks dead-ended every relocated
# (~/.memory-pack, --prefix) install — the markers existed but were read
# from a directory that did not.
SL_DIR="$(cd "$(dirname "$0")" && pwd)"
SL_PATH="$SL_DIR/$(basename "$0")"
MP_HOOKS_DIR="$(cd "$SL_DIR" && cd "$(dirname "$(readlink "$SL_PATH" 2>/dev/null || echo "$SL_PATH")")" && pwd)/hooks"
HOOKS_DIR="$MP_HOOKS_DIR"

# Find memory dir for current project (encode project_dir path)
if [ -n "$project_dir" ]; then
    encoded_proj=$(echo "$project_dir" | sed 's|[^a-zA-Z0-9]|-|g')
    mem_dir="$MEMORY_BASE/$encoded_proj/memory"
    if [ -d "$mem_dir" ]; then
        mem_lines=$(wc -l < "$mem_dir/MEMORY.md" 2>/dev/null | tr -d ' ')
        mem_bytes=$(wc -c < "$mem_dir/MEMORY.md" 2>/dev/null | tr -d ' ')
        [ -z "$mem_lines" ] && mem_lines=0
        [ -z "$mem_bytes" ] && mem_bytes=0
        mem_kb=$(( (mem_bytes + 512) / 1024 ))

        # Harness truncates MEMORY.md at 200 lines OR 25KB (=25600 bytes).
        # Soft cap 150 lines / ~19KB. Green < 75/13KB, yellow 75-115/13-19KB,
        # red 116-199/19-24KB, blinking white-on-red at hard cap.
        # (mem_lines, mem_bytes, mem_kb computed here; assembled into mem_part below)
    fi
fi


# Boot context status: read the per-session marker written by boot-inject.sh.
# The marker lands synchronously when the SessionStart hook returns and encodes
# the state directly (loaded/pending/none), so it beats the older transcript
# grep that raced the hook_additional_context attachment getting flushed.
#
# Error state takes precedence: when the previous session's replay fails,
# session-end.sh writes a synthetic boot-context titled "Replay failed for
# prior session". boot-inject.sh still sets marker=loaded for that case, so
# the replay-err overlay needs the transcript grep layered on top.
marker_file="$MP_HOOKS_DIR/.boot-marker-${session_id}"
if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    # Drill into the actual SessionStart hook_additional_context attachment
    # rather than grepping the transcript head as free text — otherwise any
    # file the assistant reads early (including this script, which contains
    # the marker strings as grep patterns) can false-positive the detection.
    boot_content=$(head -n 20 "$transcript" 2>/dev/null | jq -r '
        select(.type=="attachment"
               and .attachment.type=="hook_additional_context"
               and .attachment.hookEvent=="SessionStart")
        | .attachment.content
        | if type=="array" then .[0] else . end' 2>/dev/null | head -1)
fi

# Skip-replay opt-out: session-end.sh skips this session's replay when the
# per-project sentinel .skip-replay-<hash> exists (user asked to "skip
# replay"). <hash> = first 8 hex of md5(project_dir), exactly as derived in
# session-end.sh:28 / boot-inject.sh:35. Surface it so continuity being
# opted out for this session is visible rather than silent.
# Resolve PROJECT_KEY against CC's slug (transcript-anchored) so the hash
# matches hooks' derivation even when workspace.project_dir is empty.
proj_key=$(mp_resolve_project_key "$transcript" "$project_dir")
if [ -n "$proj_key" ]; then
    proj_hash=$(printf '%s' "$proj_key" | mp_proj_hash 2>/dev/null)
fi

# --- Source render helpers ---
# SL_DIR / MP_HOOKS_DIR already resolved above.
. "$MP_HOOKS_DIR/statusline-theme.sh"
. "$MP_HOOKS_DIR/statusline-icons.sh"
. "$MP_HOOKS_DIR/statusline-render.sh"

# CC spawns the statusline subprocess with COLUMNS=0 (v2.1.150, observed
# 2026-05-26). `${COLUMNS:-80}` only substitutes for unset/empty — "0" is
# non-empty, so the fallback never kicks in and mp_width_mode 0 → "narrow",
# silently dropping line 3 on every CC invocation. Coerce ≤0 and non-numeric
# to 80 so mp_width_mode receives a positive integer the comparisons accept.
cols="${COLUMNS:-80}"
if ! [ "$cols" -gt 0 ] 2>/dev/null; then cols=80; fi
mode=$(mp_width_mode "$cols")

ansi_fg() {
  # $1 = "R G B"
  set -- $1
  printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"
}
ansi_bg() {
  set -- $1
  printf '\033[48;2;%s;%s;%sm' "$1" "$2" "$3"
}
RESET='\033[0m'

# Model pill: pick anchor by family substring, foreground by luminance.
model_lower=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
case "$model_lower" in
  *opus*)   anchor="$THEME_PILL_OPUS_ANCHOR" ;;
  *sonnet*) anchor="$THEME_PILL_SONNET_ANCHOR" ;;
  *haiku*)  anchor="$THEME_PILL_HAIKU_ANCHOR" ;;
  *)        anchor="$THEME_PILL_OTHER_ANCHOR" ;;
esac
pill_fg=$(mp_pill_fg "$anchor")
# Compact model name for narrow modes (strip version suffixes)
pill_label=$(printf '%s' "$model" | awk '{
  s=$0; sub(/^claude-/, "", s); sub(/-[0-9.]+(\[.*\])?$/, "", s); print s
}')
[ "$mode" = "narrow" ] && pill_label=$(printf '%s' "$pill_label" | awk '{
  if (index($0,"opus"))   {print "opus"; next}
  if (index($0,"sonnet")) {print "sonnet"; next}
  if (index($0,"haiku"))  {print "haiku"; next}
  print $0
}')
pill="$(ansi_bg "$anchor")$(ansi_fg "$pill_fg") ${pill_label} ${RESET}"

# Reset format_pct to use theme RGB instead of legacy 16-color ANSI.
format_pct() {
  label="$1"; val="$2"; reset_epoch="$3"
  warn_at="${4:-50}"; crit_at="${5:-80}"; bar_width="${6:-10}"
  [ "$mode" = "medium" ] && bar_width=6
  [ "$mode" = "narrow" ] && bar_width=0
  pct=$(printf '%.0f' "$val")
  if   [ "$pct" -ge "$crit_at" ] 2>/dev/null; then fill="$THEME_BAR_FILL_ALERT"
  elif [ "$pct" -ge "$warn_at" ] 2>/dev/null; then fill="$THEME_BAR_FILL_WARN"
  else                                              fill="$THEME_BAR_FILL_SAFE"
  fi
  fill_ansi=$(ansi_fg "$fill")
  empty_ansi=$(ansi_fg "$THEME_BAR_EMPTY")
  filled=$(( (pct * bar_width + 99) / 100 ))
  bar=""; i=0
  while [ $i -lt $bar_width ]; do
    if [ $i -lt $filled ]; then bar="${bar}${fill_ansi}▓"
    else                        bar="${bar}${empty_ansi}░"
    fi
    i=$((i+1))
  done
  reset_str=""
  if [ -n "$reset_epoch" ] && [ "$mode" != "narrow" ]; then
    r=$(format_reset "$reset_epoch")
    [ -n "$r" ] && reset_str=" \033[2m↻${r}${RESET}"
  fi
  if [ "$mode" = "narrow" ]; then
    printf "%s %s%s%%%%${RESET}" "$label" "$fill_ansi" "$pct"
  else
    printf "%s %s%s%%%%${RESET} %s${RESET}%s" "$label" "$fill_ansi" "$pct" "$bar" "$reset_str"
  fi
}

# --- Line 1 ---
vibe_part=""
[ -n "$vibe" ] && vibe_part=" $(ansi_fg "$THEME_FG_VIBE")${ICON_VIBE}${vibe}${RESET}"

git_part=""
if [ -n "$project_dir" ] && [ -d "$project_dir/.git" ]; then
  branch=$(git -C "$project_dir" symbolic-ref --short HEAD 2>/dev/null || git -C "$project_dir" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=""
    git -C "$project_dir" diff --quiet HEAD 2>/dev/null || dirty="$(ansi_fg "$THEME_FG_DIRTY")${ICON_DIRTY}${RESET}"
    line_info=""
    if [ "$mode" != "narrow" ]; then
      diffstat=$(git -C "$project_dir" diff HEAD --shortstat 2>/dev/null)
      adds=$(echo "$diffstat" | grep -o '[0-9]* insertion' | grep -o '[0-9]*')
      dels=$(echo "$diffstat" | grep -o '[0-9]* deletion' | grep -o '[0-9]*')
      [ -n "$adds" ] && line_info="$(ansi_fg "$THEME_FG_LINES_ADD")+${adds}${RESET}"
      if [ -n "$dels" ]; then
        [ -n "$line_info" ] && line_info="${line_info}/"
        line_info="${line_info}$(ansi_fg "$THEME_FG_LINES_DEL")-${dels}${RESET}"
      fi
    fi
    git_part=" $(ansi_fg "$THEME_FG_BRANCH")${ICON_BRANCH} ${branch}${RESET}${dirty}"
    [ -n "$line_info" ] && git_part="${git_part} ${line_info}"
  fi
fi

# Memory indicator (3-step ladder)
mem_part=""
if [ -n "$mem_lines" ] 2>/dev/null && [ "$mem_lines" -ge 0 ] 2>/dev/null; then
  if [ "$mem_lines" -ge 200 ] || [ "$mem_bytes" -ge 25600 ]; then
    mem_part=$(printf '\033[1;5;48;2;%sm 🚨 TRUNCATED %sL %sKB %s' \
      "$(echo "$THEME_FG_MEMORY_CRIT" | tr ' ' ';')" "$mem_lines" "$mem_kb" "$RESET")
  elif [ "$mem_lines" -gt 115 ] || [ "$mem_bytes" -gt 19500 ]; then
    mem_part="$(ansi_fg "$THEME_FG_MEMORY_CRIT")${ICON_MEMORY} ${mem_lines}/150"
    [ "$mode" != "narrow" ] && mem_part="${mem_part} ${mem_kb}KB"
    mem_part="${mem_part}${RESET}"
  elif [ "$mem_lines" -gt 75 ] || [ "$mem_bytes" -gt 12800 ]; then
    mem_part="$(ansi_fg "$THEME_FG_MEMORY_WARN")${ICON_MEMORY} ${mem_lines}/150"
    [ "$mode" != "narrow" ] && mem_part="${mem_part} ${mem_kb}KB"
    mem_part="${mem_part}${RESET}"
  else
    mem_part="$(ansi_fg "$THEME_FG_MEMORY_OK")${ICON_MEMORY} ${mem_lines}/150"
    [ "$mode" != "narrow" ] && mem_part="${mem_part} ${mem_kb}KB"
    mem_part="${mem_part}${RESET}"
  fi
fi

# Boot/skip overlay rebuilt with theme RGB. Detection (marker_file content,
# boot_content, proj_hash) ran earlier. Indicators are NEVER dropped in any
# width mode — silent-amnesia signal preservation.
boot_status_themed=""
if [ -n "$session_id" ] && [ -f "$marker_file" ]; then
  case "$(cat "$marker_file" 2>/dev/null)" in
    loaded)  boot_status_themed="$(ansi_fg "$THEME_FG_BOOT_OK")${ICON_BOOT_OK}booted${RESET}" ;;
    pending) boot_status_themed="$(ansi_fg "$THEME_FG_BOOT_PENDING")${ICON_BOOT_PENDING}pending${RESET}" ;;
  esac
fi
case "$boot_content" in
  "[Replay failed for prior session"*)
    boot_status_themed="$(ansi_fg "$THEME_FG_BOOT_ERR")${ICON_BOOT_ERR}replay-err${RESET}" ;;
esac

skip_themed=""
if [ -n "$proj_hash" ] && [ -f "$HOOKS_DIR/.skip-replay-${proj_hash}" ]; then
  skip_themed="$(ansi_fg "$THEME_FG_SKIP_REPLAY")${ICON_SKIP_REPLAY}skip-replay${RESET}"
fi

cont_display=""
sep=" \033[2m│${RESET} "
overlay=""
[ -n "$mem_part" ]           && overlay="${mem_part}"
[ -n "$boot_status_themed" ] && overlay="${overlay:+${overlay} }${boot_status_themed}"
[ -n "$skip_themed" ]        && overlay="${overlay:+${overlay} }${skip_themed}"
[ -n "$overlay" ]            && cont_display="${sep}${overlay}"

printf "$(ansi_fg "$THEME_FG_PWD")%s${RESET}%b ${pill}%b%b\n" \
  "${ICON_PWD}${ICON_PWD:+ }${dir}" "$vibe_part" "$git_part" "$cont_display"

# --- Line 2 ---
parts=""
if [ -n "$ctx" ] && [ "$ctx" != "0" ]; then
  parts="$(format_pct "$(ansi_fg "$THEME_FG_CTX_ICON")${ICON_CTX}${RESET} ctx" "$ctx")"
fi
if [ -n "$five_h" ]; then
  [ -n "$parts" ] && parts="${parts}${sep}"
  parts="${parts}$(format_pct "$(ansi_fg "$THEME_FG_5H_ICON")${ICON_5H}${RESET} 5h" "$five_h" "$five_h_reset" 80 90)"
fi
if [ -n "$seven_d" ]; then
  [ -n "$parts" ] && parts="${parts}${sep}"
  seven_d_warn=80
  if [ -n "$seven_d_reset" ]; then
    days_left=$(( (seven_d_reset - $(date +%s)) / 86400 ))
    [ "$days_left" -lt 0 ] && days_left=0
    [ "$days_left" -gt 7 ] && days_left=7
    days_elapsed=$(( 7 - days_left ))
    seven_d_warn=$(( days_elapsed * 100 / 7 ))
    [ "$seven_d_warn" -lt 14 ] && seven_d_warn=14
  fi
  parts="${parts}$(format_pct "$(ansi_fg "$THEME_FG_7D_ICON")${ICON_7D}${RESET} 7d" "$seven_d" "$seven_d_reset" "$seven_d_warn" 90 10)"
fi
# $parts is used AS the printf FORMAT string — format_pct must emit %%%% (not %)
# for literal %, and \033 literals (not real ESC) for ANSI escapes, so this
# outer printf converts them. Do NOT add bare %s/%d to format_pct's output.
[ -n "$parts" ] && printf "${parts}\n"

# --- Line 3: turn-rate sparkline (full + medium only) ---
if [ "$mode" != "narrow" ]; then
  TOKEN_LOG="$HOME/.claude/statusline-token-rate.log"
  if [ -f "$TOKEN_LOG" ] && [ -n "$session_id" ]; then
    deltas=$(mp_sparkline_data "$TOKEN_LOG" "$session_id")
    if [ -n "$deltas" ]; then
      bars=$(mp_sparkline_render "$deltas")
      if [ "$mode" = "full" ]; then
        # "last" + "peak" stats next to the bars.
        last=$(printf '%s' "$deltas" | awk '{printf "%d", $NF}')
        peak=$(printf '%s' "$deltas" | awk '{ m=0; for(i=1;i<=NF;i++) if ($i+0 > m) m=$i+0; printf "%d", m }')
        last_s=$(awk -v n="$last" 'BEGIN { if (n >= 1000000) printf "%.1fM", n/1000000; else if (n >= 1000) printf "%.1fK", n/1000; else printf "%d", n }')
        peak_s=$(awk -v n="$peak" 'BEGIN { if (n >= 1000000) printf "%.1fM", n/1000000; else if (n >= 1000) printf "%.1fK", n/1000; else printf "%d", n }')
        # Double-quote format string so ${RESET} expands; printf then interprets \033.
        printf "\033[2mturn${RESET} %b  \033[2mlast${RESET} %s \033[2m·${RESET} \033[2mpeak${RESET} %s\n" "$bars" "$last_s" "$peak_s"
      else
        printf '%b\n' "$bars"
      fi
    fi
  fi
fi
