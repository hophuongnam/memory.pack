# shellcheck shell=sh
# Memory.Pack statusline render helpers.
#
# Sourced AFTER hooks/statusline-theme.sh. Pure functions, each unit-testable.
# All math in awk one-liners — POSIX sh has no float ops. None of these
# functions touch the filesystem except mp_sparkline_data (reads one log).
#
# Functions:
#   mp_pill_fg <"R G B">             — luminance-flip fg picker
#   mp_gradient_color <ratio>        — interpolate THEME_GRAD_STOPS at ratio∈[0,1]
#   mp_sparkline_data <log> <sid>    — read log, output up to 16 deltas (space-sep)
#   mp_sparkline_render <deltas>     — render colored ▁..█ bars from delta list
#   mp_width_mode <cols>             — print "full" / "medium" / "narrow"

# mp_pill_fg: given an anchor RGB tuple "R G B", pick THEME_PILL_FG_DARK
# (Y ≥ 128) or THEME_PILL_FG_LIGHT (Y < 128) per ITU-R BT.601 luminance.
# Y = 0.299·R + 0.587·G + 0.114·B. Threshold inclusive at 128 → dark.
# Prints "R G B" of the chosen foreground.
mp_pill_fg() {
  printf '%s\n' "$1" | awk -v dark="$THEME_PILL_FG_DARK" -v light="$THEME_PILL_FG_LIGHT" '{
    y = 0.299*$1 + 0.587*$2 + 0.114*$3
    # `> 127` is equivalent to `>= 128` for integer RGB in [0,255] and avoids
    # the IEEE 754 rounding where 0.299+0.587+0.114 ≠ 1.0 exactly — without
    # it, anchor "128 128 128" yields y=127.999… and misses the boundary.
    print (y > 127 ? dark : light)
  }'
}

# mp_gradient_color: given a ratio t ∈ [0,1], interpolate THEME_GRAD_STOPS
# linearly between the two flanking stops and print "R G B". Clamps t to
# [0,1]. Stops format: "<t>:R,G,B <t>:R,G,B …" sorted ascending by t.
mp_gradient_color() {
  printf '%s\n' "$1" | awk -v stops="$THEME_GRAD_STOPS" '
    BEGIN {
      n = split(stops, parts, " ")
      for (i = 1; i <= n; i++) {
        split(parts[i], kv, ":")
        st[i] = kv[1] + 0
        split(kv[2], rgb, ",")
        sr[i] = rgb[1] + 0
        sg[i] = rgb[2] + 0
        sb[i] = rgb[3] + 0
      }
      nstops = n
    }
    {
      t = $1 + 0
      if (t <= 0)      { printf "%d %d %d", sr[1], sg[1], sb[1]; exit }
      if (t >= 1)      { printf "%d %d %d", sr[nstops], sg[nstops], sb[nstops]; exit }
      for (i = 1; i < nstops; i++) {
        if (t >= st[i] && t <= st[i+1]) {
          span = st[i+1] - st[i]
          u    = (span > 0) ? (t - st[i]) / span : 0
          r    = int(sr[i] + (sr[i+1] - sr[i]) * u + 0.5)
          g    = int(sg[i] + (sg[i+1] - sg[i]) * u + 0.5)
          b    = int(sb[i] + (sb[i+1] - sb[i]) * u + 0.5)
          printf "%d %d %d", r, g, b
          exit
        }
      }
      # Unreachable for well-formed sorted stops [0,1]; guards malformed input
      # (unsorted, or sparse range like 0.2→0.9 leaving a hole). Emits last
      # stop as a safe-ish fallback rather than empty output.
      printf "%d %d %d", sr[nstops], sg[nstops], sb[nstops]
    }'
}

# mp_sparkline_data: read a token-rate log (<epoch> <sid> <cum_tokens>),
# filter by session_id, compute deltas between consecutive cumulative
# samples (clamping negative deltas to 0), take the last 16. Output a
# single line of space-separated decimal deltas. Empty output if the log
# is missing or the session has fewer than 2 samples. Note: a session
# with all-equal samples emits a row of "0"s, not empty — mp_sparkline_render
# handles ratio=0 as the min glyph.
mp_sparkline_data() {
  log="$1"
  sid="$2"
  [ -f "$log" ] || return 0
  awk -v sid="$sid" '
    $2 == sid {
      cur = $3 + 0
      if (NR_seen++ >= 1) {
        d = cur - prev
        if (d < 0) d = 0
        deltas[++count] = d
      }
      prev = cur
    }
    END {
      start = (count > 16) ? count - 16 + 1 : 1
      out = ""
      for (i = start; i <= count; i++) {
        out = (out == "") ? deltas[i] : out " " deltas[i]
      }
      if (out != "") print out
    }
  ' "$log"
}

# mp_sparkline_render: given a space-separated list of non-negative deltas,
# render an ANSI sparkline using the 8 block-height glyphs ▁▂▃▄▅▆▇█. Each
# bar's height is scaled against the max delta in the list; each bar's color
# comes from mp_gradient_color at the same ratio. Empty input → empty out.
mp_sparkline_render() {
  printf '%s\n' "$1" | awk -v stops="$THEME_GRAD_STOPS" '
    BEGIN {
      glyph[1] = "▁"; glyph[2] = "▂"; glyph[3] = "▃"; glyph[4] = "▄"
      glyph[5] = "▅"; glyph[6] = "▆"; glyph[7] = "▇"; glyph[8] = "█"
      ns = split(stops, parts, " ")
      for (i = 1; i <= ns; i++) {
        split(parts[i], kv, ":")
        st[i] = kv[1] + 0
        split(kv[2], rgb, ",")
        sr[i] = rgb[1] + 0; sg[i] = rgb[2] + 0; sb[i] = rgb[3] + 0
      }
    }
    {
      n = NF
      if (n == 0) exit
      mx = 0
      for (i = 1; i <= n; i++) { v = $i + 0; if (v > mx) mx = v }
      out = ""
      for (i = 1; i <= n; i++) {
        v = $i + 0
        ratio = (mx > 0) ? v / mx : 0
        # Glyph index: bars of height 0 → ▁ (idx 1); ratio 1 → █ (idx 8).
        idx = int(ratio * 7) + 1
        if (idx > 8) idx = 8
        if (idx < 1) idx = 1
        # Gradient color at the same ratio.
        r = sr[ns]; g = sg[ns]; b = sb[ns]
        if (ratio <= 0)      { r = sr[1];  g = sg[1];  b = sb[1] }
        else if (ratio >= 1) { r = sr[ns]; g = sg[ns]; b = sb[ns] }
        else {
          for (j = 1; j < ns; j++) {
            if (ratio >= st[j] && ratio <= st[j+1]) {
              span = st[j+1] - st[j]
              u    = (span > 0) ? (ratio - st[j]) / span : 0
              r    = int(sr[j] + (sr[j+1] - sr[j]) * u + 0.5)
              g    = int(sg[j] + (sg[j+1] - sg[j]) * u + 0.5)
              b    = int(sb[j] + (sb[j+1] - sb[j]) * u + 0.5)
              break
            }
          }
        }
        out = out sprintf("\033[38;2;%d;%d;%dm%s\033[0m", r, g, b, glyph[idx])
      }
      print out
    }
  '
}

# mp_width_mode: given a column count, print "full" (> 80), "medium"
# (56-80), or "narrow" (≤ 55). Boundaries chosen to match YAS conventions
# (80 = classic terminal width, 55 = comfortable split-pane).
mp_width_mode() {
  cols="${1:-80}"
  if [ "$cols" -gt 80 ] 2>/dev/null; then
    printf 'full'
  elif [ "$cols" -ge 56 ] 2>/dev/null; then
    printf 'medium'
  else
    printf 'narrow'
  fi
}
