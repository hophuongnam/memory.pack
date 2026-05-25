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

  # Just below threshold (Y=100) → light. Pins the light branch close to the
  # boundary so downward threshold drift (e.g. y > 50) gets caught — without
  # this, the threshold could slide from 128 down to 1 and no test would fire.
  fg=$(pill_fg_for "100 100 100")
  [ "$fg" = "235 235 235" ] && ok "Y=100 below threshold picks light" || bad "Y=100 below threshold picks light" "got '$fg'"
fi

# ─── mp_gradient_color interpolation ──────────────────────────────────────
if [ -f "$RENDER" ]; then
  grad_color_for() {
    sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && . "$4" && mp_gradient_color "$5"' \
      _ "$HOOKS/_lib.sh" "$THEME" "$HOOKS/statusline-icons.sh" "$RENDER" "$1"
  }

  # Stop boundaries: at t=0.00 → first stop (40 210 80)
  c=$(grad_color_for 0.00)
  [ "$c" = "40 210 80" ] && ok "gradient t=0.00 hits first stop" || bad "gradient t=0.00 hits first stop" "got '$c'"

  # At t=1.00 → last stop (170 60 210)
  c=$(grad_color_for 1.00)
  [ "$c" = "170 60 210" ] && ok "gradient t=1.00 hits last stop" || bad "gradient t=1.00 hits last stop" "got '$c'"

  # At t=0.25 → second stop exact (240 230 20)
  c=$(grad_color_for 0.25)
  [ "$c" = "240 230 20" ] && ok "gradient t=0.25 hits second stop" || bad "gradient t=0.25 hits second stop" "got '$c'"

  # Halfway between 0.00 (40,210,80) and 0.25 (240,230,20):
  # t=0.125; u=0.5 → r=(40+240)/2=140, g=(210+230)/2=220, b=(80+20)/2=50
  c=$(grad_color_for 0.125)
  [ "$c" = "140 220 50" ] && ok "gradient mid-interpolation correct" || bad "gradient mid-interpolation correct" "got '$c'"

  # Halfway between 0.25 (240,230,20) and 0.50 (255,140,20):
  # t=0.375; u=0.5 → r=(240+255)/2=247.5→248, g=(230+140)/2=185, b=(20+20)/2=20
  # Pins the SECOND segment, so an off-by-one in the segment-loop counter would fail
  # this even though stop-boundary tests still pass.
  c=$(grad_color_for 0.375)
  [ "$c" = "248 185 20" ] && ok "gradient second-segment interpolation correct" || bad "gradient second-segment interpolation correct" "got '$c'"

  # Clamp: t < 0 → first stop
  c=$(grad_color_for "-0.5")
  [ "$c" = "40 210 80" ] && ok "gradient clamps t<0 to first" || bad "gradient clamps t<0 to first" "got '$c'"

  # Clamp: t > 1 → last stop
  c=$(grad_color_for "1.5")
  [ "$c" = "170 60 210" ] && ok "gradient clamps t>1 to last" || bad "gradient clamps t>1 to last" "got '$c'"
fi

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
