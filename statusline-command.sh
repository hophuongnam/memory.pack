#!/bin/sh
# Claude Code status line - two-line display
# Line 1: folder + model + git + active tools
# Line 2: context %, 5h limit, 7d limit
#
# All usage data comes from Claude Code stdin (see
# https://code.claude.com/docs/en/statusline). rate_limits is absent until
# the first API response of a session, so the 5h/7d segments drop silently
# on the very first render.

input=$(cat)

# --- Stdin fields (session-specific) ---
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')
dir=$(basename "$project_dir")
model=$(echo "$input" | jq -r '.model.display_name // empty')
ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
transcript=$(echo "$input" | jq -r '.transcript_path // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
five_h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_h_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_d_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

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

# --- Helper: format a percentage with color, mini bar, and optional reset time ---
# Usage: format_pct <label> <value> [reset_epoch] [warn_thresh] [crit_thresh] [bar_width]
format_pct() {
    label="$1"
    val="$2"
    reset_epoch="$3"
    warn_at="${4:-50}"
    crit_at="${5:-80}"
    bar_width="${6:-10}"
    pct=$(printf '%.0f' "$val")

    # Color: green < warn, yellow warn..(crit-1), red >= crit
    if [ "$pct" -ge "$crit_at" ] 2>/dev/null; then
        color="\033[1;31m"
    elif [ "$pct" -ge "$warn_at" ] 2>/dev/null; then
        color="\033[1;33m"
    else
        color="\033[1;32m"
    fi

    # Mini progress bar
    filled=$(( (pct * bar_width + 99) / 100 ))
    bar=""
    i=0
    while [ $i -lt $bar_width ]; do
        if [ $i -lt $filled ]; then
            bar="${bar}${color}▓"
        else
            bar="${bar}\033[2;37m░"
        fi
        i=$((i+1))
    done

    reset_str=""
    if [ -n "$reset_epoch" ]; then
        r=$(format_reset "$reset_epoch")
        [ -n "$r" ] && reset_str=" \033[2m↻${r}\033[0m"
    fi

    printf "%s %s%s%%%%\033[0m %s\033[0m%s" \
        "$label" "$color" "$pct" "$bar" "$reset_str"
}

# --- Git info (branch + dirty + lines changed) ---
git_part=""
if [ -n "$project_dir" ] && [ -d "$project_dir/.git" ]; then
    branch=$(git -C "$project_dir" symbolic-ref --short HEAD 2>/dev/null || git -C "$project_dir" rev-parse --short HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        dirty=""
        if ! git -C "$project_dir" diff --quiet HEAD 2>/dev/null; then
            dirty="*"
        fi
        # Lines added/removed (unstaged + staged vs HEAD)
        diffstat=$(git -C "$project_dir" diff HEAD --shortstat 2>/dev/null)
        adds=$(echo "$diffstat" | grep -o '[0-9]* insertion' | grep -o '[0-9]*')
        dels=$(echo "$diffstat" | grep -o '[0-9]* deletion' | grep -o '[0-9]*')
        line_info=""
        [ -n "$adds" ] && line_info="\033[32m+${adds}\033[0m"
        if [ -n "$dels" ]; then
            [ -n "$line_info" ] && line_info="${line_info}/"
            line_info="${line_info}\033[31m-${dels}\033[0m"
        fi
        git_part=" \033[2;36m ${branch}${dirty}\033[0m"
        [ -n "$line_info" ] && git_part="${git_part} ${line_info}"
    fi
fi

# --- Continuity system status ---
continuity_part=""
HOOK_STATE_DIR="$HOME/.claude/hook_state"
MEMORY_BASE="$HOME/.claude/projects"
HOOKS_DIR="$HOME/Resilio.Sync/Memory.Pack/hooks"

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
        if [ "$mem_lines" -ge 200 ] || [ "$mem_bytes" -ge 25600 ]; then
            # Hard truncation reached — content is being silently dropped.
            continuity_part="\033[1;5;37;41m 🚨 TRUNCATED ${mem_lines}L ${mem_kb}KB \033[0m"
        elif [ "$mem_lines" -gt 115 ] || [ "$mem_bytes" -gt 19500 ]; then
            continuity_part="\033[1;31m🧠 ${mem_lines}/150 ${mem_kb}KB\033[0m"
        elif [ "$mem_lines" -gt 75 ] || [ "$mem_bytes" -gt 12800 ]; then
            continuity_part="\033[1;33m🧠 ${mem_lines}/150 ${mem_kb}KB\033[0m"
        else
            continuity_part="\033[1;32m🧠 ${mem_lines}/150 ${mem_kb}KB\033[0m"
        fi
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
boot_status=""
marker_file="$HOME/Resilio.Sync/Memory.Pack/hooks/.boot-marker-${session_id}"
if [ -n "$session_id" ] && [ -f "$marker_file" ]; then
    case "$(cat "$marker_file" 2>/dev/null)" in
        loaded)
            boot_status="\033[2;32m✓booted\033[0m" ;;
        pending)
            boot_status="\033[2;33m⏳pending\033[0m" ;;
    esac
fi
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
    case "$boot_content" in
        "[Replay failed for prior session"*)
            boot_status="\033[1;31m⚠replay-err\033[0m" ;;
    esac
fi

# Skip-replay opt-out: session-end.sh skips this session's replay when the
# per-project sentinel .skip-replay-<hash> exists (user asked to "skip
# replay"). <hash> = first 8 hex of md5(project_dir), exactly as derived in
# session-end.sh:28 / boot-inject.sh:35. Surface it so continuity being
# opted out for this session is visible rather than silent.
skip_part=""
if [ -n "$project_dir" ]; then
    proj_hash=$(printf '%s' "$project_dir" | mp_proj_hash 2>/dev/null)
    if [ -n "$proj_hash" ] && [ -f "$HOOKS_DIR/.skip-replay-${proj_hash}" ]; then
        skip_part="\033[1;33m⏭skip-replay\033[0m"
    fi
fi

[ -n "$continuity_part" ] && continuity_part="${continuity_part} "
continuity_part="${continuity_part}${boot_status}"
# Append the skip indicator. Guard against a doubled separator: when
# boot_status was empty, continuity_part still ends in the space added just
# above, so append directly in that case.
if [ -n "$skip_part" ]; then
    case "$continuity_part" in
        "")    continuity_part="$skip_part" ;;
        *" ")  continuity_part="${continuity_part}${skip_part}" ;;
        *)     continuity_part="${continuity_part} ${skip_part}" ;;
    esac
fi

# --- Line 1: folder + vibe + model + git ---
vibe_part=""
if [ -n "$vibe" ]; then
    vibe_part=" \033[1;35m⚡${vibe}\033[0m"
fi

cont_display=""
if [ -n "$continuity_part" ]; then
    cont_display=" \033[2m│\033[0m ${continuity_part}"
fi

printf "\033[1;37m%s\033[0m%b \033[2m· %s\033[0m%b%b\n" "$dir" "$vibe_part" "$model" "$git_part" "$cont_display"

# --- Line 2: limits with mini bars ---
parts=""
sep="\033[2m │ \033[0m"

if [ -n "$ctx" ] && [ "$ctx" != "0" ]; then
    parts="$(format_pct "\033[36m◐\033[0m ctx" "$ctx")"
fi
if [ -n "$five_h" ]; then
    [ -n "$parts" ] && parts="${parts}${sep}"
    parts="${parts}$(format_pct "\033[35m⏱\033[0m 5h" "$five_h" "$five_h_reset" 80 90)"
fi
if [ -n "$seven_d" ]; then
    [ -n "$parts" ] && parts="${parts}${sep}"
    # Pace-adaptive warn: days_elapsed/7 * 100. Daily step jumps.
    seven_d_warn=80
    if [ -n "$seven_d_reset" ]; then
        days_left=$(( (seven_d_reset - $(date +%s)) / 86400 ))
        [ "$days_left" -lt 0 ] && days_left=0
        [ "$days_left" -gt 7 ] && days_left=7
        days_elapsed=$(( 7 - days_left ))
        seven_d_warn=$(( days_elapsed * 100 / 7 ))
        [ "$seven_d_warn" -lt 14 ] && seven_d_warn=14
    fi
    parts="${parts}$(format_pct "\033[34m⏳\033[0m 7d" "$seven_d" "$seven_d_reset" "$seven_d_warn" 90 10)"
fi

if [ -n "$parts" ]; then
    printf "${parts}\n"
fi
