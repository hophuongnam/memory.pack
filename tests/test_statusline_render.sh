#!/bin/bash
# TDD: hooks/statusline-render.sh + theme + icons. Each helper sourced and
# called against fixture inputs; outputs pinned. Snapshot-style structural
# checks for the statusline-command.sh integration come later.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HERE/../hooks"
THEME="$HOOKS/statusline-theme.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# ─── theme schema ─────────────────────────────────────────────────────────
[ -f "$THEME" ] || { echo "FAIL  hooks/statusline-theme.sh missing"; exit 1; }

# theme must produce no stdout/stderr at source time (stray echo → silently
# corrupts the rendered statusline, the silent-amnesia class).
src_out=$(sh -c '. "$1" 2>&1' _ "$THEME")
[ -z "$src_out" ] && ok "theme sources silently" || bad "theme sources silently" "got: $src_out"

# Source in a subshell to check var exports without polluting the test env.
THEME_VARS=$(sh -c '. "$1" && set | grep "^THEME_" | sort' _ "$THEME")
expected_vars="
THEME_BAR_EMPTY
THEME_BAR_FILL_ALERT
THEME_BAR_FILL_SAFE
THEME_BAR_FILL_WARN
THEME_FG_5H_ICON
THEME_FG_7D_ICON
THEME_FG_BOOT_ERR
THEME_FG_BOOT_OK
THEME_FG_BOOT_PENDING
THEME_FG_BRANCH
THEME_FG_CTX_ICON
THEME_FG_DIRTY
THEME_FG_LINES_ADD
THEME_FG_LINES_DEL
THEME_FG_MEMORY_CRIT
THEME_FG_MEMORY_OK
THEME_FG_MEMORY_WARN
THEME_FG_PWD
THEME_FG_SKIP_REPLAY
THEME_FG_VIBE
THEME_GRAD_STOPS
THEME_NAME
THEME_PILL_FG_DARK
THEME_PILL_FG_LIGHT
THEME_PILL_HAIKU_ANCHOR
THEME_PILL_OPUS_ANCHOR
THEME_PILL_OTHER_ANCHOR
THEME_PILL_SONNET_ANCHOR
"
for v in $expected_vars; do
  echo "$THEME_VARS" | grep -q "^$v=" && ok "theme exports $v" || bad "theme exports $v"
done

# THEME_GRAD_STOPS must be parseable as "<float>:R,G,B [<float>:R,G,B ...]"
gs=$(sh -c '. "$1" && printf "%s" "$THEME_GRAD_STOPS"' _ "$THEME")
echo "$gs" | grep -qE '^([01]\.[0-9]+:[0-9]+,[0-9]+,[0-9]+( |$))+$' \
  && ok "THEME_GRAD_STOPS well-formed" || bad "THEME_GRAD_STOPS well-formed" "got: $gs"

# ─── icons schema + Nerd Font selection ───────────────────────────────────
ICONS="$HOOKS/statusline-icons.sh"
[ -f "$ICONS" ] || bad "hooks/statusline-icons.sh exists"

if [ -f "$ICONS" ]; then
  # Source-time silence contract (both modes — invariant against stray echo
  # in either branch of the if/else).
  for mode in 1 0; do
    icons_out=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT="$3" . "$4" 2>&1' _ "$HOOKS/_lib.sh" "$THEME" "$mode" "$ICONS")
    [ -z "$icons_out" ] && ok "icons sources silently (NERDFONT=$mode)" || bad "icons sources silently (NERDFONT=$mode)" "got: $icons_out"
  done

  # With Nerd Font forced on, ICON_BRANCH should be the Nerd glyph (E0A0 = ).
  # With Nerd Font forced off, ICON_BRANCH should be the Unicode fallback ().
  ICON_BRANCH_NERD=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && printf "%s" "$ICON_BRANCH"' _ "$HOOKS/_lib.sh" "$THEME" "$ICONS")
  ICON_BRANCH_UNI=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=0 . "$3" && printf "%s" "$ICON_BRANCH"' _ "$HOOKS/_lib.sh" "$THEME" "$ICONS")

  [ -n "$ICON_BRANCH_NERD" ] && ok "ICON_BRANCH set with Nerd Font on" || bad "ICON_BRANCH set with Nerd Font on"
  [ -n "$ICON_BRANCH_UNI" ]  && ok "ICON_BRANCH set with Nerd Font off" || bad "ICON_BRANCH set with Nerd Font off"
  [ "$ICON_BRANCH_NERD" != "$ICON_BRANCH_UNI" ] \
    && ok "ICON_BRANCH differs between Nerd/Unicode tables" \
    || bad "ICON_BRANCH differs between Nerd/Unicode tables" "both: '$ICON_BRANCH_NERD'"

  # Every expected ICON_* var must be set under at least one mode.
  for icon in ICON_BRANCH ICON_DIRTY ICON_PWD ICON_MEMORY ICON_BOOT_OK ICON_BOOT_PENDING \
              ICON_BOOT_ERR ICON_SKIP_REPLAY ICON_CTX ICON_5H ICON_7D ICON_VIBE; do
    val=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && printf "%s" "${'"$icon"':-}"' _ "$HOOKS/_lib.sh" "$THEME" "$ICONS")
    [ -n "$val" ] && ok "$icon exports under Nerd Font" || bad "$icon exports under Nerd Font"
  done

  # Fallback (NERDFONT=0) existence — protects against typos in the else
  # branch that would silently no-op without this. Skip ICON_PWD: the
  # Unicode fallback table intentionally leaves it empty (no widely-rendered
  # folder glyph that beats omitting it).
  for icon in ICON_BRANCH ICON_DIRTY ICON_MEMORY ICON_BOOT_OK ICON_BOOT_PENDING \
              ICON_BOOT_ERR ICON_SKIP_REPLAY ICON_CTX ICON_5H ICON_7D ICON_VIBE; do
    val=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=0 . "$3" && printf "%s" "${'"$icon"':-}"' _ "$HOOKS/_lib.sh" "$THEME" "$ICONS")
    [ -n "$val" ] && ok "$icon exports under Unicode fallback" || bad "$icon exports under Unicode fallback"
  done
fi

# ─── mp_pill_fg luminance flip ────────────────────────────────────────────
RENDER="$HOOKS/statusline-render.sh"
[ -f "$RENDER" ] || bad "hooks/statusline-render.sh exists"

if [ -f "$RENDER" ]; then
  # Source-time silence contract — pure function definitions, no top-level
  # side effects. Catches stray echo/printf in helper definitions.
  render_out=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && . "$4" 2>&1' _ "$HOOKS/_lib.sh" "$THEME" "$HOOKS/statusline-icons.sh" "$RENDER")
  [ -z "$render_out" ] && ok "render sources silently" || bad "render sources silently" "got: $render_out"

  pill_fg_for() {
    sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && . "$4" && mp_pill_fg "$5"' \
      _ "$HOOKS/_lib.sh" "$THEME" "$HOOKS/statusline-icons.sh" "$RENDER" "$1"
  }

  # Bright (Y=255) → dark fg
  fg=$(pill_fg_for "255 255 255")
  [ "$fg" = "15 15 15" ] && ok "white anchor → dark fg" || bad "white anchor → dark fg" "got '$fg'"

  # Black (Y=0) → light fg
  fg=$(pill_fg_for "0 0 0")
  [ "$fg" = "235 235 235" ] && ok "black anchor → light fg" || bad "black anchor → light fg" "got '$fg'"

  # Mid-gray Y=128 boundary: 128 128 128 → Y = 0.299*128+0.587*128+0.114*128 = 128
  # Threshold is Y >= 128 → dark; should pick dark.
  fg=$(pill_fg_for "128 128 128")
  [ "$fg" = "15 15 15" ] && ok "Y=128 boundary picks dark" || bad "Y=128 boundary picks dark" "got '$fg'"

  # Opus anchor (255 216 77) → Y = 0.299*255 + 0.587*216 + 0.114*77 ≈ 211.6 → dark
  fg=$(pill_fg_for "255 216 77")
  [ "$fg" = "15 15 15" ] && ok "opus anchor → dark fg" || bad "opus anchor → dark fg" "got '$fg'"
fi

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
