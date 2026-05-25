# shellcheck shell=sh
# Memory.Pack statusline theme — claude-dark variant.
#
# Sourced by statusline-command.sh and tests. Every visible color in the
# statusline derives from one of the THEME_* vars below. Adding a sibling
# theme = drop a sibling file with the same var names + a THEME_NAME line,
# ship a resolver in v2.
#
# Format conventions:
#   THEME_FG_*        — "R G B" (space-separated decimal 0-255), consumed by
#                       `printf '\033[38;2;%s;%s;%sm'` after IFS split.
#   THEME_BAR_*       — same RGB tuple format.
#   THEME_PILL_*_ANCHOR — RGB tuple, used as pill background AND as the
#                       anchor whose luminance picks dark/light foreground.
#   THEME_PILL_FG_*   — RGB tuple, fg used after luminance flip (mp_pill_fg).
#   THEME_GRAD_STOPS  — "<t>:R,G,B <t>:R,G,B ..." sorted ascending by t∈[0,1].
#                       Drives sparkline color interpolation (mp_gradient_color).

THEME_NAME="claude-dark"

# Line 1
THEME_FG_PWD="255 255 255"
THEME_FG_BRANCH="135 215 135"
THEME_FG_DIRTY="240 220 100"
THEME_FG_LINES_ADD="40 208 168"
THEME_FG_LINES_DEL="220 88 99"
THEME_FG_VIBE="199 125 255"

# Memory indicator (3-step ladder)
THEME_FG_MEMORY_OK="135 215 135"
THEME_FG_MEMORY_WARN="240 220 100"
THEME_FG_MEMORY_CRIT="220 88 99"

# Boot/skip overlay
THEME_FG_BOOT_OK="135 215 135"
THEME_FG_BOOT_PENDING="240 220 100"
THEME_FG_BOOT_ERR="220 88 99"
THEME_FG_SKIP_REPLAY="255 216 77"

# Line 2 (rate-limit segments)
THEME_FG_CTX_ICON="116 168 212"
THEME_FG_5H_ICON="203 166 247"
THEME_FG_7D_ICON="137 180 250"

# Bar fills (3-step ladder; safe < warn < alert)
THEME_BAR_FILL_SAFE="135 215 135"
THEME_BAR_FILL_WARN="240 220 40"
THEME_BAR_FILL_ALERT="220 88 99"
THEME_BAR_EMPTY="42 42 46"

# Per-model identity pill anchors (background RGB)
THEME_PILL_OPUS_ANCHOR="255 216 77"      # warm gold
THEME_PILL_SONNET_ANCHOR="135 215 135"   # green
THEME_PILL_HAIKU_ANCHOR="135 180 250"    # blue
THEME_PILL_OTHER_ANCHOR="203 166 247"    # lavender

# Pill foreground options — mp_pill_fg picks one based on anchor luminance.
THEME_PILL_FG_DARK="15 15 15"
THEME_PILL_FG_LIGHT="235 235 235"

# Sparkline gradient (5-step: green → yellow → orange → red → purple).
THEME_GRAD_STOPS="0.00:40,210,80 0.25:240,230,20 0.50:255,140,20 0.75:220,40,50 1.00:170,60,210"
