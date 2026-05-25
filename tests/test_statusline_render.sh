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

  # Interior stop boundaries — exact stop values must win even though both
  # adjacent segments satisfy the inclusive `t >= st[i] && t <= st[i+1]` test.
  # Pins the "first-match-wins-via-exit" contract for t=0.50 and t=0.75.
  c=$(grad_color_for 0.50)
  [ "$c" = "255 140 20" ] && ok "gradient t=0.50 hits third stop" || bad "gradient t=0.50 hits third stop" "got '$c'"
  c=$(grad_color_for 0.75)
  [ "$c" = "220 40 50" ] && ok "gradient t=0.75 hits fourth stop" || bad "gradient t=0.75 hits fourth stop" "got '$c'"

  # Third segment mid-point (0.50→0.75): t=0.625; u=0.5 →
  # r=(255+220)/2=237.5→238, g=(140+40)/2=90, b=(20+50)/2=35
  c=$(grad_color_for 0.625)
  [ "$c" = "238 90 35" ] && ok "gradient third-segment interpolation correct" || bad "gradient third-segment interpolation correct" "got '$c'"

  # Fourth segment mid-point (0.75→1.00): t=0.875; u=0.5 →
  # r=(220+170)/2=195, g=(40+60)/2=50, b=(50+210)/2=130
  c=$(grad_color_for 0.875)
  [ "$c" = "195 50 130" ] && ok "gradient fourth-segment interpolation correct" || bad "gradient fourth-segment interpolation correct" "got '$c'"

  # Clamp: t < 0 → first stop
  c=$(grad_color_for "-0.5")
  [ "$c" = "40 210 80" ] && ok "gradient clamps t<0 to first" || bad "gradient clamps t<0 to first" "got '$c'"

  # Clamp: t > 1 → last stop
  c=$(grad_color_for "1.5")
  [ "$c" = "170 60 210" ] && ok "gradient clamps t>1 to last" || bad "gradient clamps t>1 to last" "got '$c'"
fi

# ─── mp_sparkline_data + mp_sparkline_render ──────────────────────────────
if [ -f "$RENDER" ]; then
  TMPLOG=$(mktemp)
  trap 'rm -f "$TMPLOG"' EXIT
  # Format: <epoch> <session_id> <cum_tokens>
  cat > "$TMPLOG" <<'LOG'
1779700000 sid-A 100
1779700060 sid-A 250
1779700120 sid-A 600
1779700180 sid-A 700
1779700240 sid-B 50000
1779700300 sid-A 1200
LOG

  sparkline_data_for() {
    sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && . "$4" && mp_sparkline_data "$5" "$6"' \
      _ "$HOOKS/_lib.sh" "$THEME" "$HOOKS/statusline-icons.sh" "$RENDER" "$1" "$2"
  }

  # sid-A has 4 cum samples (100, 250, 600, 700, 1200 — wait, 5).
  # Deltas: 250-100=150, 600-250=350, 700-600=100, 1200-700=500.
  # 4 deltas total.
  deltas=$(sparkline_data_for "$TMPLOG" "sid-A")
  [ "$deltas" = "150 350 100 500" ] && ok "sparkline data: sid-A 4 deltas" \
    || bad "sparkline data: sid-A 4 deltas" "got '$deltas'"

  # sid-B has 1 sample → 0 deltas (need ≥2 samples for a delta).
  deltas=$(sparkline_data_for "$TMPLOG" "sid-B")
  [ -z "$deltas" ] && ok "sparkline data: sid-B no deltas (1 sample)" \
    || bad "sparkline data: sid-B no deltas" "got '$deltas'"

  # Missing log file → empty output, no error.
  if deltas=$(sparkline_data_for "/nonexistent/log" "sid-A" 2>&1); then
    [ -z "$deltas" ] && ok "sparkline data: missing log → empty" \
      || bad "sparkline data: missing log → empty" "got '$deltas'"
  else
    bad "sparkline data: missing log doesn't error" "exit nonzero"
  fi

  # Render: given known deltas, output non-empty ANSI string with 4 bars.
  sparkline_render_for() {
    sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && . "$4" && mp_sparkline_render "$5"' \
      _ "$HOOKS/_lib.sh" "$THEME" "$HOOKS/statusline-icons.sh" "$RENDER" "$1"
  }
  rendered=$(sparkline_render_for "150 350 100 500")
  [ -n "$rendered" ] && ok "sparkline render: non-empty for 4 deltas" \
    || bad "sparkline render: non-empty for 4 deltas"
  echo "$rendered" | grep -q $'\033\[38;2;' \
    && ok "sparkline render: contains truecolor ANSI" \
    || bad "sparkline render: contains truecolor ANSI"
  # Max delta is 500 → final bar should be at ratio 1.0 (last gradient stop:
  # purple 170,60,210). Look for that exact RGB in output.
  echo "$rendered" | grep -q '38;2;170;60;210' \
    && ok "sparkline render: max bar uses last gradient stop" \
    || bad "sparkline render: max bar uses last gradient stop" "got: '$rendered'"

  # Min bar (only positive delta is 0) → still emits something (glyph idx 1
  # = ▁). Pins ratio=0 → glyph[1] mapping; a regression that defaults to
  # glyph[8] (full block) for zero-height would emit a block here.
  rendered=$(sparkline_render_for "0 100 0 100")
  echo "$rendered" | grep -q '▁' \
    && ok "sparkline render: zero deltas emit min glyph" \
    || bad "sparkline render: zero deltas emit min glyph" "got: '$rendered'"

  # All-equal non-zero deltas → ratio=1 for every bar → max glyph + last
  # gradient stop color across the line. Pins the all-max case.
  rendered=$(sparkline_render_for "50 50 50")
  echo "$rendered" | grep -q '█' \
    && ok "sparkline render: all-equal deltas → max glyph" \
    || bad "sparkline render: all-equal deltas → max glyph" "got: '$rendered'"

  # 16-delta cap: log with 20 samples of sid-C, should output exactly 19 deltas
  # truncated to the last 16. (Verifies the start = count - 16 + 1 formula.)
  cat >> "$TMPLOG" <<'LOG2'
1779800001 sid-C 100
1779800002 sid-C 200
1779800003 sid-C 300
1779800004 sid-C 400
1779800005 sid-C 500
1779800006 sid-C 600
1779800007 sid-C 700
1779800008 sid-C 800
1779800009 sid-C 900
1779800010 sid-C 1000
1779800011 sid-C 1100
1779800012 sid-C 1200
1779800013 sid-C 1300
1779800014 sid-C 1400
1779800015 sid-C 1500
1779800016 sid-C 1600
1779800017 sid-C 1700
1779800018 sid-C 1800
1779800019 sid-C 1900
1779800020 sid-C 2000
LOG2
  deltas=$(sparkline_data_for "$TMPLOG" "sid-C")
  # 20 samples → 19 deltas; capped at 16. Each delta is exactly 100 (all same).
  count_deltas=$(printf '%s' "$deltas" | awk '{print NF}')
  [ "$count_deltas" = "16" ] && ok "sparkline data: cap at 16 deltas" \
    || bad "sparkline data: cap at 16 deltas" "got count=$count_deltas, deltas='$deltas'"

  # Negative delta (cum count went DOWN — shouldn't happen but data could be
  # corrupted) → clamped to 0, doesn't propagate negative bar.
  cat >> "$TMPLOG" <<'LOG3'
1779900001 sid-D 1000
1779900002 sid-D 500
1779900003 sid-D 800
LOG3
  deltas=$(sparkline_data_for "$TMPLOG" "sid-D")
  [ "$deltas" = "0 300" ] && ok "sparkline data: negative delta clamped to 0" \
    || bad "sparkline data: negative delta clamped to 0" "got '$deltas'"

  # Empty input → empty output.
  rendered=$(sparkline_render_for "")
  [ -z "$rendered" ] && ok "sparkline render: empty input → empty" \
    || bad "sparkline render: empty input → empty" "got '$rendered'"
fi

# ─── mp_width_mode threshold logic ────────────────────────────────────────
if [ -f "$RENDER" ]; then
  width_mode_for() {
    sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && . "$4" && mp_width_mode "$5"' \
      _ "$HOOKS/_lib.sh" "$THEME" "$HOOKS/statusline-icons.sh" "$RENDER" "$1"
  }

  [ "$(width_mode_for 200)" = "full" ]   && ok "cols=200 → full"   || bad "cols=200 → full"
  [ "$(width_mode_for 81)"  = "full" ]   && ok "cols=81 → full"    || bad "cols=81 → full"
  [ "$(width_mode_for 80)"  = "medium" ] && ok "cols=80 → medium"  || bad "cols=80 → medium"
  [ "$(width_mode_for 56)"  = "medium" ] && ok "cols=56 → medium"  || bad "cols=56 → medium"
  [ "$(width_mode_for 55)"  = "narrow" ] && ok "cols=55 → narrow"  || bad "cols=55 → narrow"
  [ "$(width_mode_for 1)"   = "narrow" ] && ok "cols=1 → narrow"   || bad "cols=1 → narrow"

  # Empty/missing arg → defaults to 80 → medium. Pins the `${1:-80}` default.
  [ "$(width_mode_for "")" = "medium" ] && ok "empty cols → default 80 → medium" || bad "empty cols → default 80 → medium"

  # Non-numeric input → numeric comparison fails → falls through to narrow.
  # The 2>/dev/null on the [ -gt ] keeps it silent. Pins the error-tolerant
  # path so a future "fix" that removes the redirect doesn't surface noise.
  out=$(width_mode_for "garbage" 2>&1)
  [ "$out" = "narrow" ] && ok "non-numeric cols → narrow, silent" || bad "non-numeric cols → narrow, silent" "got '$out'"
fi

# ─── snake↔camel stdin parsing on statusline-command.sh (D7, invariant #3) ─
SL="$HERE/../statusline-command.sh"
if [ -f "$SL" ]; then
  # Every jq line that extracts a CC stdin field must include `// .<camelKey> //` fallback.
  # Fields we care about: workspace.project_dir → workspace.projectDir,
  # model.display_name → model.displayName, context_window.used_percentage → contextWindow.usedPercentage,
  # transcript_path → transcriptPath, session_id → sessionId, rate_limits.* → rateLimits.*.
  for snake in 'workspace.project_dir' 'model.display_name' 'context_window.used_percentage' \
               'transcript_path' 'session_id' 'rate_limits.five_hour' 'rate_limits.seven_day'; do
    if grep -q "\.${snake}" "$SL"; then
      camel=$(printf '%s' "$snake" | awk -F. '{
        for (i=1; i<=NF; i++) {
          n = split($i, parts, "_")
          out = parts[1]
          for (j=2; j<=n; j++) out = out toupper(substr(parts[j],1,1)) substr(parts[j],2)
          $i = out
        }
        out2 = $1; for (k=2; k<=NF; k++) out2 = out2 "." $k; print out2
      }')
      if grep -q "\.${snake}" "$SL" && grep -q "\.${camel}" "$SL"; then
        ok "stdin field $snake has camelCase fallback $camel"
      else
        bad "stdin field $snake has camelCase fallback $camel"
      fi
    fi
  done
fi

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
