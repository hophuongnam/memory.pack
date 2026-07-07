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
              ICON_BOOT_ERR ICON_SKIP_REPLAY ICON_CTX ICON_5H ICON_7D ICON_VIBE ICON_TURNS; do
    val=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && printf "%s" "${'"$icon"':-}"' _ "$HOOKS/_lib.sh" "$THEME" "$ICONS")
    [ -n "$val" ] && ok "$icon exports under Nerd Font" || bad "$icon exports under Nerd Font"
  done

  # Fallback (NERDFONT=0) existence — protects against typos in the else
  # branch that would silently no-op without this. Skip ICON_PWD: the
  # Unicode fallback table intentionally leaves it empty (no widely-rendered
  # folder glyph that beats omitting it).
  for icon in ICON_BRANCH ICON_DIRTY ICON_MEMORY ICON_BOOT_OK ICON_BOOT_PENDING \
              ICON_BOOT_ERR ICON_SKIP_REPLAY ICON_CTX ICON_5H ICON_7D ICON_VIBE ICON_TURNS; do
    val=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=0 . "$3" && printf "%s" "${'"$icon"':-}"' _ "$HOOKS/_lib.sh" "$THEME" "$ICONS")
    [ -n "$val" ] && ok "$icon exports under Unicode fallback" || bad "$icon exports under Unicode fallback"
  done

  # ICON_MEMORY (Nerd table) must be the BRAIN glyph (md-brain, U+F09D1), not
  # the person/account silhouette (md-account, U+F0004). U+F0004 renders as a
  # man silhouette — the reported symptom. No PUA literal in this source (it
  # doesn't survive markdown roundtrips), so assert on the resolved codepoint
  # via python3. Doubles as a mutation guard: reverting to F0004 fails loudly.
  mem_cp=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && printf "%s" "$ICON_MEMORY"' \
    _ "$HOOKS/_lib.sh" "$THEME" "$ICONS" \
    | python3 -c 'import sys; s=sys.stdin.read(); print(("%X"%ord(s[0])) if s else "EMPTY")')
  [ "$mem_cp" = "F09D1" ] \
    && ok "ICON_MEMORY (Nerd) is md-brain U+F09D1" \
    || bad "ICON_MEMORY (Nerd) is md-brain U+F09D1 (F0004=md-account silhouette)" "got U+$mem_cp"
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

# ─── stdin extraction: ONE jq pass (statusline renders on every CC event) ─
# Each jq fork costs ~30-40ms (boot-inject.sh:6-9 measured it and collapsed
# its 4 calls into 1 for exactly this reason). The statusline re-renders on
# every prompt/assistant-message/tool-use event; 11 per-field forks burned
# ~400ms per render. Budget: 1 jq for the stdin fields + 1 for the
# boot_content transcript drill (+1 slack). The 128 behavioral assertions
# in this suite are the field-correctness contract; this pins the fork count.
SL="$HERE/../statusline-command.sh"
if [ -f "$SL" ]; then
  njq=$(grep -v '^[[:space:]]*#' "$SL" | grep -c '| jq')
  if [ "$njq" -le 3 ]; then
    ok "stdin extraction: ≤3 jq invocations in statusline-command.sh (got $njq)"
  else
    bad "stdin extraction: ≤3 jq invocations in statusline-command.sh" \
        "got $njq — per-field forks crept back"
  fi
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

# ─── statusline-command.sh integration: full mode ─────────────────────────
FIX="$HERE/fixtures"

if [ -f "$SL" ]; then
  # Sandbox HOME so the script doesn't read the real user's marker files.
  TMPHOME=$(mktemp -d); trap 'rm -rf "$TMPHOME" "$TMPLOG"' EXIT
  mkdir -p "$TMPHOME/.claude"
  # Provide a token-rate log with a known shape so the sparkline renders.
  cat > "$TMPHOME/.claude/statusline-token-rate.log" <<'LOG'
1779700000 test-session-full 100
1779700060 test-session-full 250
1779700120 test-session-full 600
1779700180 test-session-full 700
1779700240 test-session-full 1200
1779700300 test-session-full 1800
LOG

  out=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX/statusline-stdin-full.json" 2>/dev/null)

  # 3 lines in full mode (use printf '%s\n' to restore the trailing newline
  # that $() strips — wc -l counts newlines, so 3 lines = 3 newlines).
  lc=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lc" = "3" ] && ok "full mode: 3 output lines" || bad "full mode: 3 output lines" "got $lc; out: $out"

  # Line 1 contains the model pill — look for a 48;2;R;G;B (background ANSI)
  echo "$out" | head -n 1 | grep -q $'\033\[48;2;' \
    && ok "full mode: model pill renders truecolor bg" \
    || bad "full mode: model pill renders truecolor bg"

  # Line 1 contains the directory name
  echo "$out" | head -n 1 | grep -q 'test-project' \
    && ok "full mode: dir name on line 1" \
    || bad "full mode: dir name on line 1"

  # Line 2 contains "ctx", "5h", and "7d" labels
  echo "$out" | sed -n '2p' | grep -q 'ctx' \
    && ok "full mode: ctx label on line 2" \
    || bad "full mode: ctx label on line 2"
  echo "$out" | sed -n '2p' | grep -q '5h' \
    && ok "full mode: 5h label on line 2" \
    || bad "full mode: 5h label on line 2"
  echo "$out" | sed -n '2p' | grep -q '7d' \
    && ok "full mode: 7d label on line 2" \
    || bad "full mode: 7d label on line 2"

  # Line 3 contains a sparkline glyph (any of ▁..█)
  echo "$out" | sed -n '3p' | grep -qE '[▁▂▃▄▅▆▇█]' \
    && ok "full mode: sparkline glyph on line 3" \
    || bad "full mode: sparkline glyph on line 3"

  # Line 3 contains "turn" label (full mode only)
  echo "$out" | sed -n '3p' | grep -q 'turn' \
    && ok "full mode: turn label on line 3" \
    || bad "full mode: turn label on line 3"
fi

# ─── statusline-command.sh integration: medium mode ───────────────────────
if [ -f "$SL" ]; then
  out=$(COLUMNS=72 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX/statusline-stdin-full.json" 2>/dev/null)

  lc=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lc" = "3" ] && ok "medium mode: still 3 lines (sparkline kept)" \
    || bad "medium mode: still 3 lines (sparkline kept)" "got $lc; out: $out"

  # Medium mode drops the "turn" / "last" / "peak" labels on line 3.
  if echo "$out" | sed -n '3p' | grep -q 'last\|peak'; then
    bad "medium mode: drops 'last'/'peak' labels"
  else
    ok "medium mode: drops 'last'/'peak' labels"
  fi

  # But the sparkline glyphs are still there.
  echo "$out" | sed -n '3p' | grep -qE '[▁▂▃▄▅▆▇█]' \
    && ok "medium mode: sparkline glyphs still present" \
    || bad "medium mode: sparkline glyphs still present"

  # Bar width drops 10 → 6 (count ▓+░ on the ctx segment).
  # ctx pct in fixture is 12 → 12*6/100 = 0.72 → 1 filled, 5 empty.
  ctx_line=$(echo "$out" | sed -n '2p')
  bar_chars=$(echo "$ctx_line" | grep -oE '[▓░]' | wc -l | tr -d ' ')
  # Total bar chars across ctx + 5h + 7d in medium mode = 6 + 6 + 6 = 18.
  [ "$bar_chars" = "18" ] && ok "medium mode: bar width = 6 per segment (18 total)" \
    || bad "medium mode: bar width = 6 per segment" "got $bar_chars"
fi

# ─── statusline-command.sh integration: narrow mode ───────────────────────
if [ -f "$SL" ]; then
  out=$(COLUMNS=48 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX/statusline-stdin-full.json" 2>/dev/null)

  lc=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lc" = "2" ] && ok "narrow mode: 2 lines (no sparkline)" \
    || bad "narrow mode: 2 lines (no sparkline)" "got $lc; out: $out"

  # No sparkline glyphs anywhere.
  if echo "$out" | grep -qE '[▁▂▃▄▅▆▇█]'; then
    bad "narrow mode: no sparkline glyphs"
  else
    ok "narrow mode: no sparkline glyphs"
  fi

  # No bars on 5h / 7d (just percentages).
  bar_chars=$(echo "$out" | sed -n '2p' | grep -oE '[▓░]' | wc -l | tr -d ' ')
  [ "$bar_chars" = "0" ] && ok "narrow mode: no bars (just %)" \
    || bad "narrow mode: no bars" "got $bar_chars bars"

  # Boot indicator still present (silent-amnesia signal, never dropped).
  # Set up a marker file in the real HOOKS_DIR so the script's mp_resolve_project_key
  # → marker_file path resolves to it.
  HOOKS_TEST_DIR="$HERE/../hooks"
  marker="$HOOKS_TEST_DIR/.boot-marker-test-session-full"
  echo "loaded" > "$marker"
  trap 'rm -rf "$TMPHOME" "$TMPLOG" "$marker"' EXIT
  out2=$(COLUMNS=48 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX/statusline-stdin-full.json" 2>/dev/null)
  echo "$out2" | grep -q 'booted' \
    && ok "narrow mode: boot indicator (✓booted) preserved" \
    || bad "narrow mode: boot indicator preserved" "out2: $out2"

  # Model pill compacted to bare 'opus' in narrow mode (drops version suffix).
  # Check for ' opus ' (with spaces — the pill format is " ${pill_label} ")
  # so 'opus-4' (un-compacted) does NOT match. Pins the narrow compaction step.
  echo "$out2" | head -n 1 | grep -q ' opus ' \
    && ok "narrow mode: pill label compacted to 'opus'" \
    || bad "narrow mode: pill label compacted to 'opus'" "got: $(echo "$out2" | head -1)"
fi

# ─── statusline-command.sh integration: COLUMNS=0/empty/unset ──────────────
# CC spawns the statusline subprocess with COLUMNS=0 (observed empirically on
# v2.1.150). Naive `${COLUMNS:-80}` does NOT substitute for "0" (only for
# unset/empty), so cols stays 0 → mp_width_mode → "narrow" → line 3 silently
# dropped on every CC invocation. That was the real user-reported symptom:
# "I never see line 3 in practice." The default MUST kick in for cols ≤ 0
# (and for non-numeric — covered by the narrow-fallthrough in mp_width_mode
# itself, but the statusline-command.sh assignment is what feeds it).
if [ -f "$SL" ]; then
  for cols_setting in "COLUMNS=0" "COLUMNS=" ""; do
    eval "out=\$($cols_setting HOME=\"\$TMPHOME\" MEMORY_PACK_NERDFONT=0 bash \"\$SL\" < \"\$FIX/statusline-stdin-full.json\" 2>/dev/null)"

    lc=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
    label="${cols_setting:-COLUMNS unset}"
    [ "$lc" = "3" ] && ok "$label: 3 lines (line 3 renders)" \
      || bad "$label: 3 lines (line 3 renders)" "got $lc; out: $out"

    # Line 3 must contain a sparkline glyph — proves the cols-coerce-to-default
    # branch reaches mp_sparkline_render, not just any 3rd line of output.
    echo "$out" | sed -n '3p' | grep -qE '[▁▂▃▄▅▆▇█]' \
      && ok "$label: sparkline glyph on line 3" \
      || bad "$label: sparkline glyph on line 3"
  done
fi

# ─── cache-age clock REMOVED (2026-06-10) ─────────────────────────────────
# CC re-invokes the statusline on EVENTS (prompt / assistant message / tool
# use), not on a timer (reference_cc_statusline_event_driven.md) — a "live"
# clock can't tick, so the displayed age was a stale per-render snapshot
# serving no purpose. The feature is removed; these assertions pin the
# removal so it can't silently creep back, and that renders no longer
# litter hooks/ with per-session .statusline-clock-* anchor files (~230
# accumulated before removal, with no GC).
if [ -f "$SL" ]; then
  HOOKS_TEST_DIR="$HERE/../hooks"
  CLOCK_SID="test-session-clockless"
  CLOCK_FILE="$HOOKS_TEST_DIR/.statusline-clock-${CLOCK_SID}"
  trap 'rm -rf "$TMPHOME" "$TMPLOG" "$marker"; rm -f "$HOOKS_TEST_DIR"/.statusline-clock-test-session-*' EXIT

  FIX_CLOCKLESS="$TMPHOME/.claude/stdin-clockless.json"
  jq ".session_id = \"$CLOCK_SID\"" "$FIX/statusline-stdin-full.json" > "$FIX_CLOCKLESS"

  rm -f "$CLOCK_FILE"
  out=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX_CLOCKLESS" 2>/dev/null)
  line1=$(echo "$out" | head -n 1)

  # No per-session anchor file side effect.
  [ ! -f "$CLOCK_FILE" ] \
    && ok "clock removed: render creates no .statusline-clock-<sid> anchor" \
    || bad "clock removed: render creates no .statusline-clock-<sid> anchor" "created: $CLOCK_FILE"

  # No m:ss / h:mm:ss clock token on line 1 (nothing else on line 1 renders
  # a colon-separated duration; git/mem segments are colon-free).
  if echo "$line1" | grep -qE '[0-9]+:[0-9][0-9]'; then
    bad "clock removed: no duration token on line 1" "line 1: $line1"
  else
    ok "clock removed: no duration token on line 1"
  fi

  # Structural: no clock plumbing left in the renderer or the command.
  if grep -v '^[[:space:]]*#' "$RENDER" | grep -q 'mp_clock_format'; then
    bad "clock removed: mp_clock_format gone from statusline-render.sh" "function still defined"
  else
    ok "clock removed: mp_clock_format gone from statusline-render.sh"
  fi
  if grep -v '^[[:space:]]*#' "$SL" | grep -q 'statusline-clock'; then
    bad "clock removed: no .statusline-clock reference in statusline-command.sh" "reference remains"
  else
    ok "clock removed: no .statusline-clock reference in statusline-command.sh"
  fi
fi

# ─── statusline-command.sh integration: turns-until-autosave countdown ─────
# auto-save-stop.sh caches "<since_last> <interval>" to hook_state/<sid>_turns
# every Stop; the statusline reads it (plain shell `read`, NO jq) and shows
# "<remaining>↓" on line 1 so the user can anticipate the SAVE_INTERVAL
# auto-save block. remaining = interval - since, clamped ≥0; color escalates
# as the save nears (OK > 30% of interval, WARN ≤30%, CRIT ≤10%). Absent file
# (turn 0 / headless) → indicator hidden. Reuses TMPHOME/FIX set up above.
if [ -f "$SL" ]; then
  # Remove any boot marker for this fixture session: ✓booted's OK color
  # (THEME_FG_BOOT_OK) is byte-identical to the turns OK color
  # (THEME_FG_MEMORY_OK = 135;215;135), so leaving it would let a wrong-color
  # turns indicator pass the OK assertion. With it gone, each color code below
  # is unique to the turns indicator on line 1.
  rm -f "$HERE/../hooks/.boot-marker-test-session-full"
  TURNS_HS="$TMPHOME/.claude/hook_state"; mkdir -p "$TURNS_HS"
  TURNS_FILE="$TURNS_HS/test-session-full_turns"   # session_id from the fixture
  OK_RGB='38;2;135;215;135'; WARN_RGB='38;2;240;220;100'; CRIT_RGB='38;2;220;88;99'

  turns_line1() {  # $1 = "<since> <interval>" → line 1 of the render
    printf '%s\n' "$1" > "$TURNS_FILE"
    COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" \
      < "$FIX/statusline-stdin-full.json" 2>/dev/null | head -n 1
  }

  # since=12, interval=50 → remaining 38 (>15) → OK green.
  l1=$(turns_line1 "12 50")
  echo "$l1" | grep -q '38↓' \
    && ok "turns: remaining 38 shown as '38↓' on line 1" \
    || bad "turns: remaining 38 shown as '38↓'" "line1: $l1"
  echo "$l1" | grep -q "$OK_RGB" \
    && ok "turns: 38 remaining (>30% of 50) → OK green" \
    || bad "turns: 38 remaining → OK green" "line1: $l1"

  # since=40 → remaining 10 (≤15, >5) → WARN yellow.
  l1=$(turns_line1 "40 50")
  { echo "$l1" | grep -q '10↓' && echo "$l1" | grep -q "$WARN_RGB"; } \
    && ok "turns: 10 remaining (≤30% of 50) → WARN yellow '10↓'" \
    || bad "turns: 10 remaining → WARN yellow" "line1: $l1"

  # since=47 → remaining 3 (≤5) → CRIT red.
  l1=$(turns_line1 "47 50")
  { echo "$l1" | grep -q '3↓' && echo "$l1" | grep -q "$CRIT_RGB"; } \
    && ok "turns: 3 remaining (≤10% of 50) → CRIT red '3↓'" \
    || bad "turns: 3 remaining → CRIT red" "line1: $l1"

  # since > interval → remaining clamped to 0 (never negative).
  l1=$(turns_line1 "55 50")
  echo "$l1" | grep -q '0↓' \
    && ok "turns: since>interval clamps remaining to '0↓'" \
    || bad "turns: since>interval clamps to '0↓'" "line1: $l1"
  echo "$l1" | grep -q -- '-5↓' \
    && bad "turns: clamp prevents negative remaining" "got '-5↓'" \
    || ok "turns: clamp prevents negative remaining (no '-5↓')"

  # Corrupt / torn / tampered turns file must NOT kill the whole render. Our
  # writer only ever emits integers, but a partial write leaving a float
  # ("1.5") would otherwise hit a /bin/sh arithmetic syntax error and blank
  # the ENTIRE statusline (every line) — the silent-failure class this engine
  # hardens against. Each corrupt form must render line 1 with no indicator.
  for bad_val in "1.5 50" "x 50" "12 5x" "garbage"; do
    printf '%s\n' "$bad_val" > "$TURNS_FILE"
    l1=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" \
      < "$FIX/statusline-stdin-full.json" 2>/dev/null | head -n 1)
    if echo "$l1" | grep -q 'test-project' && ! echo "$l1" | grep -q '↓'; then
      ok "turns: corrupt file '$bad_val' → line 1 renders, no indicator"
    else
      bad "turns: corrupt file '$bad_val' renders safely" "line1: $l1"
    fi
    # The FATAL variant is dash (Linux /bin/sh): an unguarded $(( )) on
    # these values aborts the whole script there, not just a line. Run the
    # same case under real dash where present (macOS + CI ubuntu both ship
    # it) so the guard is proven against the shell that actually dies.
    if command -v dash >/dev/null 2>&1; then
      dl1=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 dash "$SL" \
        < "$FIX/statusline-stdin-full.json" 2>/dev/null | head -n 1)
      if echo "$dl1" | grep -q 'test-project' && ! echo "$dl1" | grep -q '↓'; then
        ok "turns (dash): corrupt file '$bad_val' → line 1 renders, no indicator"
      else
        bad "turns (dash): corrupt file '$bad_val' renders safely" "line1: $dl1"
      fi
    fi
  done

  # Absent turns file → NO countdown indicator (turn 0 / headless graceful).
  rm -f "$TURNS_FILE"
  l1=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" \
    < "$FIX/statusline-stdin-full.json" 2>/dev/null | head -n 1)
  echo "$l1" | grep -q '↓' \
    && bad "turns: absent file → no indicator" "saw '↓' with no turns file: $l1" \
    || ok "turns: absent turns file → no countdown indicator (graceful)"
fi

# ─── Nerd table in PRODUCTION: statusline-command.sh must source _lib.sh ──
# statusline-command.sh sourced theme/icons/render but NOT _lib.sh, so
# _mp_have_nerdfont (defined only in _lib.sh) was undefined at icons.sh:28:
# `if _mp_have_nerdfont 2>/dev/null` exited 127 → else branch → the Nerd
# table AND the MEMORY_PACK_NERDFONT=1 override were DEAD in production.
# The unit paths above mask it (they pre-source _lib.sh) and every earlier
# integration render pins NERDFONT=0 — this is the unmasked case.
if [ -f "$SL" ]; then
  # Expected glyph resolved from the real tables the unit-path way (no PUA
  # literals in this test source — they don't survive markdown roundtrips).
  NERD_PWD=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && printf "%s" "$ICON_PWD"' \
    _ "$HOOKS/_lib.sh" "$THEME" "$HOOKS/statusline-icons.sh")
  l1=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=1 bash "$SL" < "$FIX/statusline-stdin-full.json" 2>/dev/null | head -n 1)
  if [ -n "$NERD_PWD" ] && printf '%s' "$l1" | grep -qF "$NERD_PWD"; then
    ok "NERDFONT=1 production render shows Nerd ICON_PWD glyph"
  else
    bad "NERDFONT=1 production render shows Nerd ICON_PWD glyph" "line1: $l1"
  fi
  # Structural: _lib.sh sourced BEFORE statusline-icons.sh.
  if awk '/^\. .*\/_lib\.sh"/ && !lib {lib=NR} /^\. .*statusline-icons\.sh"/ && !icons {icons=NR} END {exit !(lib && icons && lib < icons)}' "$SL"; then
    ok "statusline-command.sh sources _lib.sh before icons"
  else
    bad "statusline-command.sh sources _lib.sh before icons" "source order/presence wrong"
  fi
fi

# ─── garbage rate-limit epochs must not blank or noise the render ─────────
# resets_at flows into $(( )) at two sites (format_reset; the 7d dynamic
# warn threshold). A non-integer value (ISO timestamp, torn field) was
# FATAL under dash — Linux /bin/sh — killing the whole script mid-render;
# bash survived but spewed arithmetic syntax errors to stderr on EVERY
# render. Guard idiom: the turns-file case-int checks.
if [ -f "$SL" ]; then
  FIX_BADEPOCH="$TMPHOME/.claude/stdin-badepoch.json"
  jq '.rate_limits.five_hour.resets_at = "soon-1.5"
      | .rate_limits.seven_day.resets_at = "2026-07-07T12:00:00Z"' \
    "$FIX/statusline-stdin-full.json" > "$FIX_BADEPOCH"

  err=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX_BADEPOCH" 2>&1 >/dev/null)
  out=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX_BADEPOCH" 2>/dev/null)
  lc=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  [ "$lc" = "3" ] && ok "garbage resets_at (bash): all 3 lines render" \
    || bad "garbage resets_at (bash): all 3 lines render" "got $lc; out: $out"
  [ -z "$err" ] && ok "garbage resets_at (bash): stderr silent" \
    || bad "garbage resets_at (bash): stderr silent" "stderr: $err"

  # dash leg — the fatal one (Linux /bin/sh); macOS ships /bin/dash too.
  if command -v dash >/dev/null 2>&1; then
    dout=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 dash "$SL" < "$FIX_BADEPOCH" 2>/dev/null)
    dlc=$(printf '%s\n' "$dout" | wc -l | tr -d ' ')
    [ "$dlc" = "3" ] && ok "garbage resets_at (dash): all 3 lines render" \
      || bad "garbage resets_at (dash): all 3 lines render" "got $dlc; out: $dout"
  fi

  # Mutation guard: the int-guard must not swallow VALID epochs — the stock
  # fixture ("9999999999") keeps its ↻ countdown on line 2.
  out=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX/statusline-stdin-full.json" 2>/dev/null)
  echo "$out" | sed -n '2p' | grep -q '↻' \
    && ok "valid resets_at keeps the ↻ countdown" \
    || bad "valid resets_at keeps the ↻ countdown" "line2: $(echo "$out" | sed -n '2p')"
fi

# ─── % in model.display_name must not corrupt the line-1 printf ───────────
# ${pill} sat INSIDE the printf FORMAT string; a display_name containing %
# became printf directives → mangled line + stderr noise. The pill must
# ride a %b argument instead.
if [ -f "$SL" ]; then
  FIX_PCT="$TMPHOME/.claude/stdin-pctmodel.json"
  jq '.model.display_name = "opus 100% turbo"' "$FIX/statusline-stdin-full.json" > "$FIX_PCT"
  err=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX_PCT" 2>&1 >/dev/null)
  l1=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX_PCT" 2>/dev/null | head -n 1)
  printf '%s' "$l1" | grep -qF '100% turbo' \
    && ok "percent in display_name renders literally on line 1" \
    || bad "percent in display_name renders literally on line 1" "line1: $l1"
  [ -z "$err" ] && ok "percent in display_name: stderr silent" \
    || bad "percent in display_name: stderr silent" "stderr: $err"
fi

# ─── fork-budget pins (the statusline renders on every CC event) ──────────
if [ -f "$SL" ]; then
  slcode=$(grep -v '^[[:space:]]*#' "$SL")
  n=$(printf '%s\n' "$slcode" | grep -c 'date +%s')
  [ "$n" = "1" ] && ok "exactly one date +%s fork per render (got $n)" \
    || bad "exactly one date +%s fork per render" "got $n"
  n=$(printf '%s\n' "$slcode" | grep -c 'git -C "$project_dir" diff')
  [ "$n" = "1" ] && ok "one git-diff fork (shortstat doubles as the dirty probe)" \
    || bad "one git-diff fork (shortstat doubles as the dirty probe)" "got $n"
  printf '%s\n' "$slcode" | grep -q 'cat "[^"]*vibeCodingMethod" *|' \
    && bad "vibe read: tr reads the file directly (no cat| pipeline)" "cat pipeline present" \
    || ok "vibe read: tr reads the file directly (no cat| pipeline)"
  printf '%s\n' "$slcode" | grep -q 'echo "$input" *| *jq' \
    && bad "stdin extraction: printf|jq, not echo|jq" "echo pipeline present" \
    || ok "stdin extraction: printf|jq, not echo|jq"
fi

# ─── gradient math single-source in the renderer ───────────────────────────
# mp_gradient_color had ZERO production callers while mp_sparkline_render
# inlined IDENTICAL interpolation math — a drift trap (fix one, forget the
# other). Both awk programs must embed the shared MP_AWK_GRAD function
# body, leaving exactly one copy of the interpolation expression.
if [ -f "$RENDER" ]; then
  n=$(grep -cE 'sr\[[ij]\+1\] - sr\[[ij]\]' "$RENDER")
  [ "$n" = "1" ] && ok "gradient interpolation math defined exactly once (got $n)" \
    || bad "gradient interpolation math defined exactly once" "got $n"
  n=$(grep -c 'MP_AWK_GRAD' "$RENDER")
  [ "$n" -ge 3 ] && ok "MP_AWK_GRAD shared: definition + both embeds (got $n)" \
    || bad "MP_AWK_GRAD shared: definition + both embeds" "got $n"
  # Value parity: a mid-scale sparkline bar's color must equal
  # mp_gradient_color at the same ratio ("1 2" → bar 1 ratio 0.5).
  mid=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && . "$4" && mp_gradient_color 0.5' \
    _ "$HOOKS/_lib.sh" "$THEME" "$ICONS" "$RENDER")
  spark=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && . "$4" && mp_sparkline_render "1 2"' \
    _ "$HOOKS/_lib.sh" "$THEME" "$ICONS" "$RENDER")
  printf '%s' "$spark" | grep -qF "38;2;$(printf '%s' "$mid" | tr ' ' ';')m" \
    && ok "sparkline mid-bar color == mp_gradient_color 0.5 (value parity)" \
    || bad "sparkline mid-bar color == mp_gradient_color 0.5 (value parity)" "mid=$mid"
fi

# ─── icon↔label separator space (the "⏳pending"→"⏳ending" overlap fix) ─────
# Wide glyphs — Nerd PUA (clock/warning/fast-forward/bolt) AND the Unicode
# fallback emoji (⏳ ⏭ ⚠ ⚡) — paint two cells but many terminals advance the
# cursor only one, so a label jammed against the glyph gets its first letter
# drawn ON the glyph's right half (the reported "pending" overlap; the vibe
# ⚡SPP has the same defect). Every OTHER indicator (mem/ctx/5h/7d/turns/pwd)
# already puts a space between icon and label — the A/B proof the space is the
# fix: ICON_MEMORY is *also* a wide glyph in the same render and never overlaps.
# The five boot/skip/vibe sites did not. Fix = one space at each site.
#
# Primary guard is STRUCTURAL and table-agnostic: the render string is
# identical whichever icon table filled the ICON_* var, so this pins the fix
# without depending on the terminal's Nerd/Unicode selection.
if [ -f "$SL" ]; then
  assert_spaced() {  # $1 = jammed form (must be ABSENT)  $2 = spaced (PRESENT)
    grep -qF "$1" "$SL" \
      && bad "icon-label separator present" "jammed '$1' still in statusline-command.sh" \
      || ok "icon-label separator: no jammed '$1'"
    grep -qF "$2" "$SL" \
      && ok "icon-label separator: spaced '$2' present" \
      || bad "icon-label separator missing" "expected '$2' in statusline-command.sh"
  }
  assert_spaced '${ICON_VIBE}${vibe}'             '${ICON_VIBE} ${vibe}'
  assert_spaced '${ICON_BOOT_OK}booted'           '${ICON_BOOT_OK} booted'
  assert_spaced '${ICON_BOOT_PENDING}pending'     '${ICON_BOOT_PENDING} pending'
  assert_spaced '${ICON_BOOT_ERR}replay-err'      '${ICON_BOOT_ERR} replay-err'
  assert_spaced '${ICON_SKIP_REPLAY}skip-replay'  '${ICON_SKIP_REPLAY} skip-replay'
fi

# Behavioral: prove the space reaches the RENDERED byte stream in the user's
# actual table. The screenshot glyph is the Nerd clock (U+F017), not the
# Unicode hourglass — so drive NERDFONT=1 and resolve the glyph the unit-path
# way (no PUA literal in this test source; it doesn't survive md roundtrips).
if [ -f "$SL" ]; then
  NERD_PENDING=$(sh -c '. "$1" && . "$2" && MEMORY_PACK_NERDFONT=1 . "$3" && printf "%s" "$ICON_BOOT_PENDING"' \
    _ "$HOOKS/_lib.sh" "$THEME" "$ICONS")
  bmark="$HERE/../hooks/.boot-marker-test-session-full"
  printf 'pending' > "$bmark"
  bl=$(COLUMNS=200 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=1 bash "$SL" < "$FIX/statusline-stdin-full.json" 2>/dev/null)
  rm -f "$bmark"
  if [ -n "$NERD_PENDING" ] && printf '%s' "$bl" | grep -qF "$NERD_PENDING pending"; then
    ok "NERDFONT=1: pending renders glyph + space + label (no overlap)"
  else
    bad "NERDFONT=1: pending renders glyph + space + label" "render: $bl"
  fi
  if printf '%s' "$bl" | grep -qF "${NERD_PENDING}pending"; then
    bad "NERDFONT=1: no glyph-jammed-against-label in render" "found jammed 'pending'"
  else
    ok "NERDFONT=1: no glyph-jammed-against-label in render"
  fi
fi

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
