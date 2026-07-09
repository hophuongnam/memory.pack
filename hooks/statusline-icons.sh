# shellcheck shell=sh
# Memory.Pack statusline icon set — two tables (Nerd Font + Unicode fallback).
#
# Sourced AFTER _lib.sh (needs _mp_have_nerdfont). Calls the helper once and
# exports the resolved ICON_* vars. Consumers (statusline-command.sh) treat
# ICON_* as opaque strings — they don't know or care which table won.
#
# Nerd Font glyphs live in the Private Use Area (E000-F8FF and beyond);
# rendered as tofu/boxes without a Nerd Font installed. The fallback table
# uses standard Unicode that renders in any modern terminal.
#
# Glyph reference. Names below are the codepoint's ACTUAL glyph name in the
# installed Nerd Font, read out of the font's cmap with fontTools — NOT the
# name the codepoint "should" have. Three of these comments have now lied
# (ICON_MEMORY, ICON_BRANCH, and the 5h/7d pair below, which are a plain circle
# outline and a pie slice, not a timer and a calendar). Verify before editing:
#     python3 -c 'from fontTools.ttLib import TTFont; \
#       print(TTFont("<any NerdFont.ttf>").getBestCmap().get(0xF06A9))'
# See feedback_verify_nerd_glyph_codepoints_against_font in the project store.
#
#                       Nerd Font                                Unicode fallback
#   ICON_BRANCH        U+E0A0  pl-branch                       U+2387  HELM SYMBOL (⎇)
#   ICON_DIRTY         U+25CF  BLACK CIRCLE (●)                U+25CF  BLACK CIRCLE (●)
#   ICON_PWD           U+F115  fa-folder_open_o                ""      (omit in fallback)
#   ICON_MEMORY        U+F09D1 md-brain                        U+1F9E0 brain (🧠)
#   ICON_BOOT_OK       U+F00C  fa-check                        U+2713  check (✓)
#   ICON_BOOT_PENDING  U+F017  fa-clock_o                      U+23F3  hourglass (⏳)
#   ICON_BOOT_ERR      U+F071  fa-warning                      U+26A0  warning (⚠)
#   ICON_SKIP_REPLAY   U+F051  fa-step_forward                 U+23ED  next-track (⏭)
#   ICON_CTX           U+F0349 md-magnify                      U+25D0  half-circle (◐)
#   ICON_5H            U+F13AB md-timer                        U+23F1  stopwatch (⏱)
#   ICON_7D            U+F00F0 md-calendar_clock               U+23F3  hourglass (⏳)
#   ICON_VIBE          U+F0E7  fa-flash                        U+26A1  high-voltage (⚡)
#   ICON_TURNS         U+F0450 md-refresh                      U+27F3  cycle arrow (⟳)
#   ICON_SCOPED        U+F06A9 md-robot                        U+1F916 robot (🤖)

if _mp_have_nerdfont 2>/dev/null; then
  ICON_BRANCH=""
  ICON_DIRTY="●"
  ICON_PWD=""
  ICON_MEMORY="󰧑"
  ICON_BOOT_OK=""
  ICON_BOOT_PENDING=""
  ICON_BOOT_ERR=""
  ICON_SKIP_REPLAY=""
  ICON_CTX="󰍉"
  ICON_5H="󱎫"
  ICON_7D="󰃰"
  ICON_VIBE=""
  ICON_TURNS="󰑐"
  ICON_SCOPED="󰚩"
else
  ICON_BRANCH="⎇"
  ICON_DIRTY="●"
  ICON_PWD=""
  ICON_MEMORY="🧠"
  ICON_BOOT_OK="✓"
  ICON_BOOT_PENDING="⏳"
  ICON_BOOT_ERR="⚠"
  ICON_SKIP_REPLAY="⏭"
  ICON_CTX="◐"
  ICON_5H="⏱"
  ICON_7D="⏳"
  ICON_VIBE="⚡"
  ICON_TURNS="⟳"
  ICON_SCOPED="🤖"
fi
