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
