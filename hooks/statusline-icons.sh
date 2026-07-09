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
# Glyph reference (so edits don't have to guess what the bytes mean):
#                       Nerd Font                          Unicode fallback
#   ICON_BRANCH        U+E0A0  nf-pl-branch              U+2387  HELM SYMBOL (⎇)
#   ICON_DIRTY         U+25CF  BLACK CIRCLE (●)          U+25CF  BLACK CIRCLE (●)
#   ICON_PWD           U+F115  nf-fa-folder_open         ""      (omit in fallback)
#   ICON_MEMORY        U+F09D1 nf-md-brain               U+1F9E0 brain (🧠)
#   ICON_BOOT_OK       U+F00C  nf-fa-check               U+2713  check (✓)
#   ICON_BOOT_PENDING  U+F017  nf-fa-clock_o             U+23F3  hourglass (⏳)
#   ICON_BOOT_ERR      U+F071  nf-fa-warning             U+26A0  warning (⚠)
#   ICON_SKIP_REPLAY   U+F051  nf-fa-fast_forward        U+23ED  next-track (⏭)
#   ICON_CTX           U+F0349 nf-md-magnify             U+25D0  half-circle (◐)
#   ICON_5H            U+F043D nf-md-timer-stop          U+23F1  stopwatch (⏱)
#   ICON_7D            U+F0AA0 nf-md-calendar-clock      U+23F3  hourglass (⏳)
#   ICON_VIBE          U+F0E7  nf-fa-bolt                U+26A1  high-voltage (⚡)
#   ICON_TURNS         U+F0450 nf-md-autorenew           U+27F3  cycle arrow (⟳)
#   ICON_SCOPED        U+F06A9 nf-md-robot               U+1F916 robot (🤖)

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
  ICON_5H="󰐽"
  ICON_7D="󰪠"
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
