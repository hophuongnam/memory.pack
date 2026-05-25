# Statusline visual-token redesign — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-05-25-statusline-visual-tokens-design.md`

**Goal:** Rewrite `statusline-command.sh` with truecolor RGB, per-model identity pill, turn-based sparkline (last 16 turns), themed palette, width-adaptive 3-line layout, and hybrid Nerd Font auto-detect — while preserving every silent-amnesia-class invariant and fixing one latent stdin-parsing bug.

**Architecture:** POSIX `sh` + `awk`. Heavy-lifting helpers extracted into sourceable `hooks/statusline-render.sh` so each helper is unit-testable. Theme data lives in `hooks/statusline-theme.sh`. Icon set selected at runtime via `hooks/statusline-icons.sh` calling `_mp_have_nerdfont` from `_lib.sh`. One new hook `hooks/log-token-rate.sh` writes a per-Stop cumulative-token log that the statusline reads.

**Tech stack:** POSIX `sh`, `awk`, `jq`, `printf`. No new runtime dependencies beyond what the engine already requires.

**TDD discipline (per `CLAUDE.md`):** Every change goes RED → GREEN → mutation-check → revert. Watch the RED for the **right reason** (failure message), not just any failure. Mutation check: corrupt a value/character, re-run, confirm test fails, revert. Skip the discipline and the silent-amnesia class returns invisible.

---

## File structure

### New files

| Path | Responsibility |
|---|---|
| `hooks/statusline-theme.sh` | Sourced. Exports `THEME_*` env vars (RGB tuples as `"R G B"` strings, gradient stop strings, ANSI escape helpers). One fixed dark theme in v1. |
| `hooks/statusline-icons.sh` | Sourced. Calls `_mp_have_nerdfont`, selects `ICONS_NERD_*` or `ICONS_UNICODE_*` table, exports the resolved `ICON_*` vars. |
| `hooks/statusline-render.sh` | Sourced. Exports functions `mp_pill_fg`, `mp_gradient_color`, `mp_sparkline_data`, `mp_sparkline_render`, `mp_width_mode`. Pure functions, each unit-testable. |
| `hooks/log-token-rate.sh` | Stop hook. Tails transcript jsonl, extracts assistant `.message.usage`, appends `<epoch> <session_id> <cum_tokens>` to `~/.claude/statusline-token-rate.log`. Race-tolerant. |
| `tests/test_nerdfont_helper.sh` | Tests `_mp_have_nerdfont` resolution (env override + fc-list probe). |
| `tests/test_statusline_render.sh` | Tests every helper in `hooks/statusline-render.sh` via the source-and-call pattern. |
| `tests/test_log_token_rate.sh` | Behavioral subprocess test of the Stop hook against fixture transcripts. |
| `tests/fixtures/transcript-with-usage.jsonl` | Fixture transcript containing a fully-flushed assistant entry with `usage`. |
| `tests/fixtures/transcript-no-assistant.jsonl` | Fixture transcript with only user entries (race-lost path). |

### Modified files

| Path | Change |
|---|---|
| `hooks/_lib.sh` | Add `_mp_have_nerdfont` helper. |
| `install/hooks.manifest.json` | Add Stop → `log-token-rate.sh` entry (count 11 → 12). |
| `install.sh` | Add `statusline-token-rate.log` to runtime-state EXCL list; add Nerd Font tip on install. |
| `.gitignore` | Add `statusline-token-rate.log` (but this file lives in `~/.claude/`, not the repo — add for safety against accidental relocation). |
| `tests/test_settings_merge.sh` | Update `mpcount` regex to include `log-token-rate`; update count expectations 11 → 12. |
| `tests/test_install.sh` | Update count expectations 11 → 12 (lines 62, 64). |
| `tests/test_mph_resolution.sh` | Add `statusline-token-rate.log` to runtime-state scan. |
| `statusline-command.sh` | Rewrite: source the new helpers, render 2 or 3 lines, fix snake↔camel stdin parsing on every field read. |

---

## Task 1: Add `_mp_have_nerdfont` helper to `hooks/_lib.sh`

**Files:**
- Create: `tests/test_nerdfont_helper.sh`
- Modify: `hooks/_lib.sh` (append after `_mp_resolve_project_key`)

- [ ] **Step 1: Write the failing test**

Create `tests/test_nerdfont_helper.sh`:

```bash
#!/bin/bash
# TDD: _mp_have_nerdfont honors MEMORY_PACK_NERDFONT override (1/0/true/false/yes/no)
# and falls back to `fc-list :family | grep -qi 'nerd'` probe. Returns 0/1 exit
# code. No stdout. Pinned because statusline-icons.sh sources _lib.sh and
# branches on this helper to pick the Nerd vs Unicode glyph table.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../hooks/_lib.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }

[ -f "$LIB" ] || { echo "FAIL  _lib.sh missing"; exit 1; }

# shellcheck disable=SC1090
. "$LIB"

type _mp_have_nerdfont >/dev/null 2>&1 && ok "_mp_have_nerdfont defined" || bad "_mp_have_nerdfont defined"

# Env override: explicit 1/true/yes returns 0
for v in 1 true yes; do
  MEMORY_PACK_NERDFONT="$v" _mp_have_nerdfont 2>/dev/null \
    && ok "env=$v returns 0" || bad "env=$v returns 0"
done

# Env override: explicit 0/false/no returns 1
for v in 0 false no; do
  if MEMORY_PACK_NERDFONT="$v" _mp_have_nerdfont 2>/dev/null; then
    bad "env=$v returns 1"
  else
    ok "env=$v returns 1"
  fi
done

# Empty env: falls through to fc-list probe. We don't assert the outcome
# (depends on host) — just that the call doesn't crash and returns 0 or 1.
MEMORY_PACK_NERDFONT="" _mp_have_nerdfont >/dev/null 2>&1
rc=$?
{ [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; } && ok "empty env returns 0 or 1" || bad "empty env returns 0 or 1 (got $rc)"

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
```

- [ ] **Step 2: Run test, verify it fails for the right reason**

```bash
bash tests/test_nerdfont_helper.sh
```

Expected: FAIL with `_mp_have_nerdfont defined` failing (function does not exist yet) and the env-override tests failing because the function returns "command not found".

- [ ] **Step 3: Implement `_mp_have_nerdfont` in `hooks/_lib.sh`**

Append to `hooks/_lib.sh` after the existing `_mp_resolve_project_key` function:

```sh
# _mp_have_nerdfont: returns 0 if a Nerd Font is available for the statusline
# icon set, 1 otherwise. Env override MEMORY_PACK_NERDFONT={1,true,yes} forces
# yes, MEMORY_PACK_NERDFONT={0,false,no} forces no, empty/unset falls through
# to `fc-list :family | grep -qi 'nerd'`. Used by hooks/statusline-icons.sh to
# pick the glyph table. fc-list is part of fontconfig (Linux: usually present;
# macOS: present via Homebrew or system Cairo); absent → returns 1 (Unicode
# fallback wins). Never prints to stdout.
_mp_have_nerdfont() {
  case "${MEMORY_PACK_NERDFONT:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  command -v fc-list >/dev/null 2>&1 || return 1
  fc-list :family 2>/dev/null | grep -qi 'nerd'
}
```

- [ ] **Step 4: Run test, verify it passes**

```bash
bash tests/test_nerdfont_helper.sh
```

Expected: `ALL PASS`.

- [ ] **Step 5: Mutation check**

Temporarily change the env-override case in `_lib.sh` from `1|true|yes) return 0 ;;` to `1|true|yes) return 1 ;;`. Re-run the test.

Expected: FAIL with the three env=1/true/yes assertions failing.

Revert the change. Re-run. Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add tests/test_nerdfont_helper.sh hooks/_lib.sh
git commit -m "feat(lib): add _mp_have_nerdfont helper for icon-set selection"
```

---

## Task 2: Create `hooks/statusline-theme.sh` (theme data)

**Files:**
- Create: `hooks/statusline-theme.sh`
- Modify: `tests/test_statusline_render.sh` (create with theme-schema assertions)

- [ ] **Step 1: Write the failing test (schema assertions)**

Create `tests/test_statusline_render.sh`:

```bash
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

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
```

- [ ] **Step 2: Run test, verify it fails for the right reason**

```bash
bash tests/test_statusline_render.sh
```

Expected: FAIL with `hooks/statusline-theme.sh missing`.

- [ ] **Step 3: Create `hooks/statusline-theme.sh`**

```sh
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
```

- [ ] **Step 4: Run test, verify it passes**

```bash
bash tests/test_statusline_render.sh
```

Expected: `ALL PASS`.

- [ ] **Step 5: Mutation check**

Temporarily delete one line from `hooks/statusline-theme.sh` (e.g., `THEME_PILL_OPUS_ANCHOR=...`). Re-run test.

Expected: FAIL with `theme exports THEME_PILL_OPUS_ANCHOR` failing.

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add hooks/statusline-theme.sh tests/test_statusline_render.sh
git commit -m "feat(statusline): claude-dark theme palette as sourced var exports"
```

---

## Task 3: Create `hooks/statusline-icons.sh` (icon table + selection)

**Files:**
- Create: `hooks/statusline-icons.sh`
- Modify: `tests/test_statusline_render.sh` (extend with icon assertions)

- [ ] **Step 1: Extend the failing test with icon assertions**

Append to `tests/test_statusline_render.sh` BEFORE the final `echo "----"`:

```bash
# ─── icons schema + Nerd Font selection ───────────────────────────────────
ICONS="$HOOKS/statusline-icons.sh"
[ -f "$ICONS" ] || bad "hooks/statusline-icons.sh exists"

if [ -f "$ICONS" ]; then
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
fi
```

- [ ] **Step 2: Run test, verify it fails for the right reason**

```bash
bash tests/test_statusline_render.sh
```

Expected: FAIL with `hooks/statusline-icons.sh exists` failing.

- [ ] **Step 3: Create `hooks/statusline-icons.sh`**

```sh
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

if _mp_have_nerdfont 2>/dev/null; then
  ICON_BRANCH=""
  ICON_DIRTY=""
  ICON_PWD=""
  ICON_MEMORY=""
  ICON_BOOT_OK=""
  ICON_BOOT_PENDING=""
  ICON_BOOT_ERR=""
  ICON_SKIP_REPLAY=""
  ICON_CTX="󰍉"
  ICON_5H=""
  ICON_7D="󰪠"
  ICON_VIBE=""
else
  ICON_BRANCH=""
  ICON_DIRTY="*"
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
fi
```

- [ ] **Step 4: Run test, verify it passes**

```bash
bash tests/test_statusline_render.sh
```

Expected: `ALL PASS`.

- [ ] **Step 5: Mutation check**

Temporarily change the Nerd Font `ICON_BRANCH=""` line to match the Unicode `ICON_BRANCH=""` value. Re-run.

Expected: FAIL with `ICON_BRANCH differs between Nerd/Unicode tables`.

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add hooks/statusline-icons.sh tests/test_statusline_render.sh
git commit -m "feat(statusline): icon set with Nerd Font auto-detect + Unicode fallback"
```

---

## Task 4: `hooks/statusline-render.sh` — `mp_pill_fg` (luminance flip)

**Files:**
- Create: `hooks/statusline-render.sh`
- Modify: `tests/test_statusline_render.sh` (extend with pill-fg assertions)

- [ ] **Step 1: Extend the failing test with `mp_pill_fg` assertions**

Append to `tests/test_statusline_render.sh` BEFORE the final `echo "----"`:

```bash
# ─── mp_pill_fg luminance flip ────────────────────────────────────────────
RENDER="$HOOKS/statusline-render.sh"
[ -f "$RENDER" ] || bad "hooks/statusline-render.sh exists"

if [ -f "$RENDER" ]; then
  # Source dependencies in order: _lib → theme → icons → render
  # (each helper test invokes a subshell that sources them all.)
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
```

- [ ] **Step 2: Run test, verify it fails for the right reason**

```bash
bash tests/test_statusline_render.sh
```

Expected: FAIL with `hooks/statusline-render.sh exists` failing, and the four pill_fg assertions failing because `mp_pill_fg` is undefined.

- [ ] **Step 3: Create `hooks/statusline-render.sh` with `mp_pill_fg`**

```sh
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
    print (y >= 128 ? dark : light)
  }'
}
```

- [ ] **Step 4: Run test, verify it passes**

```bash
bash tests/test_statusline_render.sh
```

Expected: `ALL PASS`.

- [ ] **Step 5: Mutation check**

Temporarily change `y >= 128` to `y >= 200` in `mp_pill_fg`. Re-run.

Expected: FAIL with `Y=128 boundary picks dark` failing (Y≈128 falls below the bumped 200 threshold). Opus Y≈211.6 still passes because it exceeds 200 — that's fine, the boundary test alone proves teeth.

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add hooks/statusline-render.sh tests/test_statusline_render.sh
git commit -m "feat(statusline): mp_pill_fg luminance-flip foreground picker"
```

---

## Task 5: `hooks/statusline-render.sh` — `mp_gradient_color`

**Files:**
- Modify: `hooks/statusline-render.sh` (append `mp_gradient_color`)
- Modify: `tests/test_statusline_render.sh` (extend with gradient assertions)

- [ ] **Step 1: Extend the failing test with `mp_gradient_color` assertions**

Append to `tests/test_statusline_render.sh` BEFORE the final `echo "----"`:

```bash
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

  # Clamp: t < 0 → first stop
  c=$(grad_color_for "-0.5")
  [ "$c" = "40 210 80" ] && ok "gradient clamps t<0 to first" || bad "gradient clamps t<0 to first" "got '$c'"

  # Clamp: t > 1 → last stop
  c=$(grad_color_for "1.5")
  [ "$c" = "170 60 210" ] && ok "gradient clamps t>1 to last" || bad "gradient clamps t>1 to last" "got '$c'"
fi
```

- [ ] **Step 2: Run test, verify it fails for the right reason**

```bash
bash tests/test_statusline_render.sh
```

Expected: FAIL with the six new gradient assertions failing because `mp_gradient_color` is undefined.

- [ ] **Step 3: Append `mp_gradient_color` to `hooks/statusline-render.sh`**

Append to `hooks/statusline-render.sh`:

```sh
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
      printf "%d %d %d", sr[nstops], sg[nstops], sb[nstops]
    }'
}
```

- [ ] **Step 4: Run test, verify it passes**

```bash
bash tests/test_statusline_render.sh
```

Expected: `ALL PASS`.

- [ ] **Step 5: Mutation check**

Temporarily change `if (t <= 0)` to `if (t <= -1)` in `mp_gradient_color`. Re-run.

Expected: FAIL with `gradient clamps t<0 to first` failing (t=-0.5 no longer clamps; falls through and emits last-stop).

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add hooks/statusline-render.sh tests/test_statusline_render.sh
git commit -m "feat(statusline): mp_gradient_color linear interpolation across theme stops"
```

---

## Task 6: `hooks/statusline-render.sh` — sparkline (data + render)

**Files:**
- Modify: `hooks/statusline-render.sh` (append `mp_sparkline_data` + `mp_sparkline_render`)
- Modify: `tests/test_statusline_render.sh` (extend with sparkline assertions)

- [ ] **Step 1: Extend the failing test with sparkline assertions**

Append to `tests/test_statusline_render.sh` BEFORE the final `echo "----"`:

```bash
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

  # Empty input → empty output.
  rendered=$(sparkline_render_for "")
  [ -z "$rendered" ] && ok "sparkline render: empty input → empty" \
    || bad "sparkline render: empty input → empty" "got '$rendered'"
fi
```

- [ ] **Step 2: Run test, verify it fails for the right reason**

```bash
bash tests/test_statusline_render.sh
```

Expected: FAIL with the sparkline assertions failing because `mp_sparkline_data` and `mp_sparkline_render` are undefined.

- [ ] **Step 3: Append `mp_sparkline_data` and `mp_sparkline_render` to `hooks/statusline-render.sh`**

Append:

```sh
# mp_sparkline_data: read a token-rate log (<epoch> <sid> <cum_tokens>),
# filter by session_id, compute deltas between consecutive cumulative
# samples, take the last 16 deltas. Output a single line of space-separated
# decimal deltas. Empty output if the log is missing, the session has fewer
# than 2 samples, or no positive delta exists.
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
```

- [ ] **Step 4: Run test, verify it passes**

```bash
bash tests/test_statusline_render.sh
```

Expected: `ALL PASS`.

- [ ] **Step 5: Mutation check**

Temporarily change `if (NR_seen++ >= 1) {` to `if (NR_seen++ >= 2) {` in `mp_sparkline_data`. Re-run.

Expected: FAIL with `sparkline data: sid-A 4 deltas` failing (one delta lost).

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add hooks/statusline-render.sh tests/test_statusline_render.sh
git commit -m "feat(statusline): mp_sparkline_data + mp_sparkline_render (turn-rate bars)"
```

---

## Task 7: `hooks/statusline-render.sh` — `mp_width_mode`

**Files:**
- Modify: `hooks/statusline-render.sh` (append `mp_width_mode`)
- Modify: `tests/test_statusline_render.sh` (extend with width-mode assertions)

- [ ] **Step 1: Extend the failing test**

Append to `tests/test_statusline_render.sh` BEFORE the final `echo "----"`:

```bash
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
fi
```

- [ ] **Step 2: Run test, verify it fails for the right reason**

```bash
bash tests/test_statusline_render.sh
```

Expected: FAIL with the six new width-mode assertions failing because `mp_width_mode` is undefined.

- [ ] **Step 3: Append `mp_width_mode` to `hooks/statusline-render.sh`**

Append:

```sh
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
```

- [ ] **Step 4: Run test, verify it passes**

```bash
bash tests/test_statusline_render.sh
```

Expected: `ALL PASS`.

- [ ] **Step 5: Mutation check**

Temporarily change `-gt 80` to `-gt 79`. Re-run.

Expected: FAIL with `cols=80 → medium` failing (80 now bumps to full).

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add hooks/statusline-render.sh tests/test_statusline_render.sh
git commit -m "feat(statusline): mp_width_mode threshold helper"
```

---

## Task 8: `hooks/log-token-rate.sh` Stop hook

**Files:**
- Create: `hooks/log-token-rate.sh`
- Create: `tests/test_log_token_rate.sh`
- Create: `tests/fixtures/transcript-with-usage.jsonl`
- Create: `tests/fixtures/transcript-no-assistant.jsonl`

- [ ] **Step 1: Create the fixture transcripts**

Create `tests/fixtures/transcript-with-usage.jsonl`:

```jsonl
{"type":"user","timestamp":"2026-05-25T12:00:00Z","message":{"role":"user","content":"hello"}}
{"type":"assistant","timestamp":"2026-05-25T12:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"usage":{"input_tokens":42,"cache_creation_input_tokens":1000,"cache_read_input_tokens":500,"output_tokens":17}}}
```

Create `tests/fixtures/transcript-no-assistant.jsonl`:

```jsonl
{"type":"user","timestamp":"2026-05-25T12:00:00Z","message":{"role":"user","content":"hello"}}
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_log_token_rate.sh`:

```bash
#!/bin/bash
# TDD: hooks/log-token-rate.sh — Stop hook that tails the transcript jsonl,
# extracts the most recent assistant .message.usage, and appends a cumulative-
# token sample to ~/.claude/statusline-token-rate.log. Race-tolerant: if no
# assistant entry is in the tail window (CC hasn't flushed yet), the hook
# exits 0 silently and writes NOTHING. The next Stop catches up.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/log-token-rate.sh"
FIX="$HERE/fixtures"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[ -f "$HOOK" ] || { echo "FAIL  hooks/log-token-rate.sh missing"; exit 1; }
[ -x "$HOOK" ] || bad "hook has +x mode"

# Sandbox a HOME so the hook writes to a temp log.
SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT
export HOME="$SBX"
mkdir -p "$HOME/.claude"
LOG="$HOME/.claude/statusline-token-rate.log"

# ─── happy path: assistant entry present, log line written ────────────────
TRANSCRIPT="$FIX/transcript-with-usage.jsonl"
echo "{\"session_id\":\"sid-X\",\"transcript_path\":\"$TRANSCRIPT\",\"hook_event_name\":\"Stop\"}" \
  | bash "$HOOK"
[ "$?" -eq 0 ] && ok "hook exits 0 on happy path" || bad "hook exits 0 on happy path"
[ -f "$LOG" ] && ok "log file created" || bad "log file created"

# Line format: "<epoch> sid-X <cum>", where cum = 42 + 1000 + 500 + 17 = 1559
line=$(tail -n 1 "$LOG" 2>/dev/null)
echo "$line" | grep -qE '^[0-9]+ sid-X 1559$' \
  && ok "log line format + cumulative tokens correct" \
  || bad "log line format + cumulative tokens correct" "got '$line'"

# ─── race-tolerant: no assistant entry → no log line written ──────────────
> "$LOG"  # truncate
echo "{\"session_id\":\"sid-Y\",\"transcript_path\":\"$FIX/transcript-no-assistant.jsonl\",\"hook_event_name\":\"Stop\"}" \
  | bash "$HOOK"
[ "$?" -eq 0 ] && ok "hook exits 0 on race-lost path" || bad "hook exits 0 on race-lost path"
[ ! -s "$LOG" ] && ok "race-lost: log NOT appended" || bad "race-lost: log NOT appended" "log non-empty"

# ─── empty transcript_path → exit 0, no write ─────────────────────────────
> "$LOG"
echo '{"session_id":"sid-Z","transcript_path":"","hook_event_name":"Stop"}' \
  | bash "$HOOK"
[ "$?" -eq 0 ] && ok "empty transcript_path → exit 0" || bad "empty transcript_path → exit 0"
[ ! -s "$LOG" ] && ok "empty transcript_path: log NOT appended" || bad "empty transcript_path: log NOT appended"

# ─── nonexistent transcript file → exit 0, no write ───────────────────────
> "$LOG"
echo '{"session_id":"sid-W","transcript_path":"/nonexistent/path.jsonl","hook_event_name":"Stop"}' \
  | bash "$HOOK"
[ "$?" -eq 0 ] && ok "missing transcript file → exit 0" || bad "missing transcript file → exit 0"
[ ! -s "$LOG" ] && ok "missing transcript file: log NOT appended" || bad "missing transcript file: log NOT appended"

# ─── camelCase stdin field names also accepted (invariant #3) ─────────────
> "$LOG"
echo "{\"sessionId\":\"sid-V\",\"transcriptPath\":\"$TRANSCRIPT\",\"hookEventName\":\"Stop\"}" \
  | bash "$HOOK"
line=$(tail -n 1 "$LOG" 2>/dev/null)
echo "$line" | grep -qE '^[0-9]+ sid-V 1559$' \
  && ok "camelCase stdin accepted" \
  || bad "camelCase stdin accepted" "got '$line'"

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
```

- [ ] **Step 3: Run test, verify it fails for the right reason**

```bash
bash tests/test_log_token_rate.sh
```

Expected: FAIL with `hooks/log-token-rate.sh missing`.

- [ ] **Step 4: Implement `hooks/log-token-rate.sh`**

Create with mode `+x`:

```sh
#!/bin/sh
# Memory.Pack Stop hook: append a per-turn cumulative-token sample to
# ~/.claude/statusline-token-rate.log. statusline-command.sh tails this log
# (last 16 per session) for the turn-rate sparkline.
#
# Race-tolerant: CC's docs explicitly disclaim transcript jsonl flush
# ordering vs hook execution. If the assistant entry for this turn isn't in
# the tail window yet, exit 0 silent — the next Stop catches up because
# we write CUMULATIVE counts, not deltas.
#
# Bilingual stdin: accepts both snake_case and camelCase field names
# (invariant #3; CC field names drift between releases).

input=$(cat)

session_id=$(printf '%s' "$input" | jq -r '.session_id // .sessionId // empty' 2>/dev/null)
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // .transcriptPath // empty' 2>/dev/null)

[ -z "$session_id" ] && exit 0
[ -z "$transcript" ] && exit 0
[ -f "$transcript" ] || exit 0

usage=$(tail -n 50 "$transcript" 2>/dev/null \
  | jq -c 'select(.type=="assistant") | .message.usage' 2>/dev/null \
  | tail -n 1)
[ -z "$usage" ] && exit 0

cum=$(printf '%s' "$usage" | jq -r '
  (.input_tokens                // 0) +
  (.cache_creation_input_tokens // 0) +
  (.cache_read_input_tokens     // 0) +
  (.output_tokens               // 0)
' 2>/dev/null)
[ -z "$cum" ] && exit 0

mkdir -p "$HOME/.claude"
printf '%s %s %s\n' "$(date +%s)" "$session_id" "$cum" >> "$HOME/.claude/statusline-token-rate.log"
exit 0
```

Then:

```bash
chmod +x hooks/log-token-rate.sh
```

- [ ] **Step 5: Run test, verify it passes**

```bash
bash tests/test_log_token_rate.sh
```

Expected: `ALL PASS`.

- [ ] **Step 6: Mutation check**

Temporarily change the cumulative sum to omit `output_tokens`:

```sh
cum=$(printf '%s' "$usage" | jq -r '
  (.input_tokens                // 0) +
  (.cache_creation_input_tokens // 0) +
  (.cache_read_input_tokens     // 0)
' 2>/dev/null)
```

Re-run. Expected: FAIL with `log line format + cumulative tokens correct` (now 1542 instead of 1559).

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add hooks/log-token-rate.sh tests/test_log_token_rate.sh tests/fixtures/transcript-with-usage.jsonl tests/fixtures/transcript-no-assistant.jsonl
git commit -m "feat(hooks): log-token-rate Stop hook (race-tolerant cumulative-token log)"
```

---

## Task 9: Register new hook in manifest, update merge + install tests

**Files:**
- Modify: `install/hooks.manifest.json`
- Modify: `tests/test_settings_merge.sh`
- Modify: `tests/test_install.sh`

- [ ] **Step 1: Update the failing assertions FIRST (TDD)**

Edit `tests/test_settings_merge.sh`:

- Line 2 comment: change "11 Memory.Pack hook entries" to "12 Memory.Pack hook entries".
- Line 7 comment: change "all 11 MP entries" to "all 12 MP entries".
- Line 54 regex inside `mpcount()`: add `log-token-rate` to the alternation. The function should read:

  ```sh
  mpcount() { jq '[.hooks[]?[]?.hooks[]? | select((.command//"")|test("/hooks/(boot-inject|session-end|memory-index-reconcile|memory-index-update|memory-recall|archive-resurrect|memory-search-inject|auto-save-stop|log-token-rate)\\.sh$"))] | length' "$1"; }
  ```

- Line 56: change `[ "$c" = "11" ]` to `[ "$c" = "12" ]`. Update label too.

Edit `tests/test_install.sh`:

- Line 62 comment: change "11 MP entries" to "12 MP entries".
- Line 64: change `[ "$mp" = "11" ]` to `[ "$mp" = "12" ]`. Update label.
- Update the `jq` startswith filter line — it already matches any `$PREFIX/hooks/` path, no script-name regex to extend.

- [ ] **Step 2: Run the failing tests, verify they fail for the right reason**

```bash
bash tests/test_settings_merge.sh; bash tests/test_install.sh
```

Expected: FAIL with `all 12 MP entries present` / `12 MP entries with prefix` because the manifest still has 11.

- [ ] **Step 3: Update the manifest**

Edit `install/hooks.manifest.json`. Add this entry inside `"entries"`, right after the existing `auto-save-stop.sh` line:

```json
    { "event": "Stop",                                   "script": "log-token-rate.sh",         "timeout": 5  }
```

Final array should have 12 entries. The `Stop` event will have two hooks (`auto-save-stop.sh` and `log-token-rate.sh`); CC fires both per Stop in registration order.

- [ ] **Step 4: Run the tests, verify they pass**

```bash
bash tests/test_settings_merge.sh && bash tests/test_install.sh
```

Expected: `ALL PASS` for both.

- [ ] **Step 5: Mutation check**

Temporarily delete the `log-token-rate.sh` entry from `install/hooks.manifest.json`. Re-run.

Expected: FAIL with `all 12 MP entries present` / `12 MP entries with prefix` (back to 11).

Revert. Re-run. Expected: `ALL PASS` for both.

- [ ] **Step 6: Commit**

```bash
git add install/hooks.manifest.json tests/test_settings_merge.sh tests/test_install.sh
git commit -m "feat(install): register log-token-rate.sh Stop hook (count 11 → 12)"
```

---

## Task 10: Runtime-state recognition for `statusline-token-rate.log`

**Files:**
- Modify: `.gitignore`
- Modify: `install.sh` (EXCL list + Nerd Font tip)
- Modify: `tests/test_mph_resolution.sh`

- [ ] **Step 1: Check what the runtime-state scan currently looks like**

Read `tests/test_mph_resolution.sh` to understand the scan pattern. Look for the section asserting that runtime-state files are excluded from install/packaging.

```bash
grep -n 'runtime\|search.db\|boot-context\|skip-replay\|\.replay' tests/test_mph_resolution.sh
```

- [ ] **Step 2: Add the failing assertion**

Add to `tests/test_mph_resolution.sh` in the runtime-state-excluded section. Look for the array/list of patterns and add:

```sh
'statusline-token-rate.log'
```

…or whatever the existing pattern syntax is. The test should assert that no shipped engine artifact (under `$PREFIX/`) is or matches `statusline-token-rate.log`.

If the test currently scans only repo-relative paths and not the runtime log, ADD a new assertion block:

```bash
# statusline-token-rate.log is runtime-only — must never live under $PREFIX or the repo
find "$SRC" -name 'statusline-token-rate.log' -not -path '*/.git/*' | grep -q . \
  && bad "statusline-token-rate.log absent from repo" \
  || ok "statusline-token-rate.log absent from repo"

find "$PREFIX" -name 'statusline-token-rate.log' 2>/dev/null | grep -q . \
  && bad "statusline-token-rate.log absent from install prefix" \
  || ok "statusline-token-rate.log absent from install prefix"
```

(Adapt to whatever `$SRC` / `$PREFIX` vars the test already uses; check the test's preamble.)

- [ ] **Step 3: Run, verify it passes (or fails for absence-of-stray-file)**

```bash
bash tests/test_mph_resolution.sh
```

If a `statusline-token-rate.log` is somehow already in the repo (unlikely, but possible after development): delete it. The test should PASS once no such file exists.

If the test now also requires an updated `EXCL` array in `install.sh`, it will FAIL on a different assertion — proceed to Step 4.

- [ ] **Step 4: Update `.gitignore`**

Append to `.gitignore`:

```
# Runtime: per-Stop token-rate log written by hooks/log-token-rate.sh.
# Lives in ~/.claude/, but listed here defensively in case anyone runs the
# install with --prefix inside the repo.
statusline-token-rate.log
```

- [ ] **Step 5: Update `install.sh`**

Find the EXCL / rsync / cp filter list in `install.sh` (look for `--exclude` or an array of excluded paths). Add `statusline-token-rate.log` to the list. Also add a Nerd Font tip:

After the install completes and before the final success message, add:

```sh
if ! command -v fc-list >/dev/null 2>&1 || ! fc-list :family 2>/dev/null | grep -qi 'nerd'; then
  echo ""
  echo "Tip: install a Nerd Font (https://www.nerdfonts.com) for richer statusline"
  echo "     icons, or set MEMORY_PACK_NERDFONT=1 in your shell to opt in anyway."
fi
```

- [ ] **Step 6: Run all the affected tests**

```bash
bash tests/test_mph_resolution.sh && bash tests/test_install.sh && bash tests/test_settings_merge.sh
```

Expected: all PASS.

- [ ] **Step 7: Mutation check**

Temporarily create `statusline-token-rate.log` in the repo root (`touch statusline-token-rate.log`). Re-run `tests/test_mph_resolution.sh`. Expected: FAIL with `statusline-token-rate.log absent from repo`.

Delete the file. Re-run. Expected: `ALL PASS`.

- [ ] **Step 8: Commit**

```bash
git add .gitignore install.sh tests/test_mph_resolution.sh
git commit -m "chore(install): mark statusline-token-rate.log as runtime-only + Nerd Font tip"
```

---

## Task 11: Snake↔camel stdin parsing fix in `statusline-command.sh`

**Files:**
- Modify: `statusline-command.sh` (every `jq -r` invocation parsing CC stdin)

- [ ] **Step 1: Add a structural test asserting EVERY stdin field has camelCase fallback**

Append to `tests/test_statusline_render.sh` BEFORE the final `echo "----"`:

```bash
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
```

- [ ] **Step 2: Run, verify it fails for the right reason**

```bash
bash tests/test_statusline_render.sh
```

Expected: FAIL with `stdin field workspace.project_dir has camelCase fallback workspace.projectDir` and similar for the other fields.

- [ ] **Step 3: Update every `jq -r` field read in `statusline-command.sh`**

Read `statusline-command.sh` lines 14-23. The current pattern is:

```sh
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // empty')
```

Change each one to include the camelCase fallback:

```sh
project_dir=$(echo "$input"     | jq -r '.workspace.project_dir       // .workspace.projectDir        // empty')
dir=$(basename "$project_dir")
model=$(echo "$input"           | jq -r '.model.display_name          // .model.displayName           // empty')
ctx=$(echo "$input"             | jq -r '.context_window.used_percentage // .contextWindow.usedPercentage // empty')
transcript=$(echo "$input"      | jq -r '.transcript_path             // .transcriptPath              // empty')
session_id=$(echo "$input"      | jq -r '.session_id                  // .sessionId                   // empty')
five_h=$(echo "$input"          | jq -r '.rate_limits.five_hour.used_percentage // .rateLimits.fiveHour.usedPercentage // empty')
five_h_reset=$(echo "$input"    | jq -r '.rate_limits.five_hour.resets_at        // .rateLimits.fiveHour.resetsAt        // empty')
seven_d=$(echo "$input"         | jq -r '.rate_limits.seven_day.used_percentage  // .rateLimits.sevenDay.usedPercentage  // empty')
seven_d_reset=$(echo "$input"   | jq -r '.rate_limits.seven_day.resets_at        // .rateLimits.sevenDay.resetsAt        // empty')
```

- [ ] **Step 4: Run, verify it passes**

```bash
bash tests/test_statusline_render.sh
```

Expected: `ALL PASS` for the new D7 assertions.

- [ ] **Step 5: Mutation check**

Temporarily remove the camelCase fallback from the `project_dir` line. Re-run.

Expected: FAIL with `stdin field workspace.project_dir has camelCase fallback workspace.projectDir`.

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add statusline-command.sh tests/test_statusline_render.sh
git commit -m "fix(statusline): snake↔camel fallback on every stdin field (invariant #3)"
```

---

## Task 12: Wire helpers into `statusline-command.sh` — full mode rendering

**Files:**
- Modify: `statusline-command.sh` (significant rewrite of the rendering block)
- Modify: `tests/test_statusline_render.sh` (add full-mode snapshot test)

- [ ] **Step 1: Add a fixture stdin + full-mode snapshot test**

Create `tests/fixtures/statusline-stdin-full.json`:

```json
{
  "session_id": "test-session-full",
  "transcript_path": "/tmp/nonexistent-transcript.jsonl",
  "model": {"display_name": "claude-opus-4-7"},
  "workspace": {"project_dir": "/tmp/test-project"},
  "context_window": {"used_percentage": 12},
  "rate_limits": {
    "five_hour": {"used_percentage": 58, "resets_at": "9999999999"},
    "seven_day": {"used_percentage": 31, "resets_at": "9999999999"}
  }
}
```

Append to `tests/test_statusline_render.sh` BEFORE the final `echo "----"`:

```bash
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

  # 3 lines in full mode
  lc=$(printf '%s' "$out" | wc -l | tr -d ' ')
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
```

- [ ] **Step 2: Run, verify it fails for the right reason**

```bash
bash tests/test_statusline_render.sh
```

Expected: FAIL with most of the full-mode assertions failing because the current `statusline-command.sh` still uses hardcoded ANSI / no pill / no sparkline / only 2 lines.

- [ ] **Step 3: Rewrite the rendering block of `statusline-command.sh`**

Open `statusline-command.sh`. Keep intact: stdin parsing (with D7 fix from Task 11), `mp_proj_hash`, `mp_resolve_project_key`, `SL_DIR` / `MP_HOOKS_DIR` resolution, `format_reset` helper, git branch/dirty/diffstat computation that produces shell variables `branch`/`dirty_flag`/`adds`/`dels`, memory metric computation that produces `mem_lines`/`mem_bytes`/`mem_kb`, boot/skip detection that produces `marker_file`/`boot_content`/`proj_hash`. **Delete** the legacy `format_pct` (lines ~91-132) and the legacy rendering printfs at the bottom (lines ~276-317) — both are replaced below.

Append at the bottom (after all detection logic, replacing what was there):

```sh
# --- Source render helpers ---
# SL_DIR / MP_HOOKS_DIR already resolved above (lines ~178-181).
. "$MP_HOOKS_DIR/statusline-theme.sh"
. "$MP_HOOKS_DIR/statusline-icons.sh"
. "$MP_HOOKS_DIR/statusline-render.sh"

cols="${COLUMNS:-80}"
mode=$(mp_width_mode "$cols")

ansi_fg() {
  # $1 = "R G B"
  set -- $1
  printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"
}
ansi_bg() {
  set -- $1
  printf '\033[48;2;%s;%s;%sm' "$1" "$2" "$3"
}
RESET='\033[0m'

# Model pill: pick anchor by family substring, foreground by luminance.
model_lower=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
case "$model_lower" in
  *opus*)   anchor="$THEME_PILL_OPUS_ANCHOR" ;;
  *sonnet*) anchor="$THEME_PILL_SONNET_ANCHOR" ;;
  *haiku*)  anchor="$THEME_PILL_HAIKU_ANCHOR" ;;
  *)        anchor="$THEME_PILL_OTHER_ANCHOR" ;;
esac
pill_fg=$(mp_pill_fg "$anchor")
# Compact model name for narrow modes (strip version suffixes)
pill_label=$(printf '%s' "$model" | awk '{
  s=$0; sub(/^claude-/, "", s); sub(/-[0-9.]+(\[.*\])?$/, "", s); print s
}')
[ "$mode" = "narrow" ] && pill_label=$(printf '%s' "$pill_label" | awk '{
  if (index($0,"opus"))   {print "opus"; next}
  if (index($0,"sonnet")) {print "sonnet"; next}
  if (index($0,"haiku"))  {print "haiku"; next}
  print $0
}')
pill="$(ansi_bg "$anchor")$(ansi_fg "$pill_fg") ${pill_label} ${RESET}"

# Reset format_pct to use theme RGB instead of legacy 16-color ANSI.
format_pct() {
  label="$1"; val="$2"; reset_epoch="$3"
  warn_at="${4:-50}"; crit_at="${5:-80}"; bar_width="${6:-10}"
  [ "$mode" = "medium" ] && bar_width=6
  pct=$(printf '%.0f' "$val")
  if   [ "$pct" -ge "$crit_at" ] 2>/dev/null; then fill="$THEME_BAR_FILL_ALERT"
  elif [ "$pct" -ge "$warn_at" ] 2>/dev/null; then fill="$THEME_BAR_FILL_WARN"
  else                                              fill="$THEME_BAR_FILL_SAFE"
  fi
  fill_ansi=$(ansi_fg "$fill")
  empty_ansi=$(ansi_fg "$THEME_BAR_EMPTY")
  filled=$(( (pct * bar_width + 99) / 100 ))
  bar=""; i=0
  while [ $i -lt $bar_width ]; do
    if [ $i -lt $filled ]; then bar="${bar}${fill_ansi}▓"
    else                        bar="${bar}${empty_ansi}░"
    fi
    i=$((i+1))
  done
  reset_str=""
  if [ -n "$reset_epoch" ] && [ "$mode" != "narrow" ]; then
    r=$(format_reset "$reset_epoch")
    [ -n "$r" ] && reset_str=" \033[2m↻${r}${RESET}"
  fi
  if [ "$mode" = "narrow" ]; then
    printf "%s %s%s%%%%${RESET}" "$label" "$fill_ansi" "$pct"
  else
    printf "%s %s%s%%%%${RESET} %s${RESET}%s" "$label" "$fill_ansi" "$pct" "$bar" "$reset_str"
  fi
}

# --- Line 1 ---
vibe_part=""
[ -n "$vibe" ] && vibe_part=" $(ansi_fg "$THEME_FG_VIBE")${ICON_VIBE}${vibe}${RESET}"

git_part=""
if [ -n "$project_dir" ] && [ -d "$project_dir/.git" ]; then
  branch=$(git -C "$project_dir" symbolic-ref --short HEAD 2>/dev/null || git -C "$project_dir" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    dirty=""
    git -C "$project_dir" diff --quiet HEAD 2>/dev/null || dirty="$(ansi_fg "$THEME_FG_DIRTY")${ICON_DIRTY}${RESET}"
    line_info=""
    if [ "$mode" != "narrow" ]; then
      diffstat=$(git -C "$project_dir" diff HEAD --shortstat 2>/dev/null)
      adds=$(echo "$diffstat" | grep -o '[0-9]* insertion' | grep -o '[0-9]*')
      dels=$(echo "$diffstat" | grep -o '[0-9]* deletion' | grep -o '[0-9]*')
      [ -n "$adds" ] && line_info="$(ansi_fg "$THEME_FG_LINES_ADD")+${adds}${RESET}"
      if [ -n "$dels" ]; then
        [ -n "$line_info" ] && line_info="${line_info}/"
        line_info="${line_info}$(ansi_fg "$THEME_FG_LINES_DEL")-${dels}${RESET}"
      fi
    fi
    git_part=" $(ansi_fg "$THEME_FG_BRANCH")${ICON_BRANCH} ${branch}${RESET}${dirty}"
    [ -n "$line_info" ] && git_part="${git_part} ${line_info}"
  fi
fi

# Memory + boot continuity overlay (built largely from existing logic;
# replace the hardcoded color escapes with theme vars).
# NOTE: continuity_part was assembled earlier in this script using legacy
# \033[1;3Xm escapes. Rebuild it here with theme RGB. The boot/skip
# subexpressions already exist as boot_status / skip_part shell vars.
mem_part=""
if [ -n "$mem_lines" ] 2>/dev/null && [ "$mem_lines" -ge 0 ] 2>/dev/null; then
  if [ "$mem_lines" -ge 200 ] || [ "$mem_bytes" -ge 25600 ]; then
    mem_part=$(printf '\033[1;5;48;2;%s;%s;%sm 🚨 TRUNCATED %sL %sKB %s' \
      "$(echo "$THEME_FG_MEMORY_CRIT" | tr ' ' ';')" "$mem_lines" "$mem_kb" "$RESET")
  elif [ "$mem_lines" -gt 115 ] || [ "$mem_bytes" -gt 19500 ]; then
    mem_part="$(ansi_fg "$THEME_FG_MEMORY_CRIT")${ICON_MEMORY} ${mem_lines}/150"
    [ "$mode" != "narrow" ] && mem_part="${mem_part} ${mem_kb}KB"
    mem_part="${mem_part}${RESET}"
  elif [ "$mem_lines" -gt 75 ] || [ "$mem_bytes" -gt 12800 ]; then
    mem_part="$(ansi_fg "$THEME_FG_MEMORY_WARN")${ICON_MEMORY} ${mem_lines}/150"
    [ "$mode" != "narrow" ] && mem_part="${mem_part} ${mem_kb}KB"
    mem_part="${mem_part}${RESET}"
  else
    mem_part="$(ansi_fg "$THEME_FG_MEMORY_OK")${ICON_MEMORY} ${mem_lines}/150"
    [ "$mode" != "narrow" ] && mem_part="${mem_part} ${mem_kb}KB"
    mem_part="${mem_part}${RESET}"
  fi
fi

# Rebuild boot_status + skip_part with theme RGB. Their detection logic
# ran earlier (lines ~220-261) and set boot_status / skip_part strings —
# but those strings carry legacy 16-color escapes. Replace by reconstructing
# from the marker file value detected earlier (we already have $marker_file
# and the transcript override path). For simplicity, re-derive:
boot_status_themed=""
if [ -n "$session_id" ] && [ -f "$marker_file" ]; then
  case "$(cat "$marker_file" 2>/dev/null)" in
    loaded)  boot_status_themed="$(ansi_fg "$THEME_FG_BOOT_OK")${ICON_BOOT_OK}booted${RESET}" ;;
    pending) boot_status_themed="$(ansi_fg "$THEME_FG_BOOT_PENDING")${ICON_BOOT_PENDING}pending${RESET}" ;;
  esac
fi
case "$boot_content" in
  "[Replay failed for prior session"*)
    boot_status_themed="$(ansi_fg "$THEME_FG_BOOT_ERR")${ICON_BOOT_ERR}replay-err${RESET}" ;;
esac

skip_themed=""
if [ -n "$proj_hash" ] && [ -f "$HOOKS_DIR/.skip-replay-${proj_hash}" ]; then
  skip_themed="$(ansi_fg "$THEME_FG_SKIP_REPLAY")${ICON_SKIP_REPLAY}skip-replay${RESET}"
fi

cont_display=""
sep=" \033[2m│${RESET} "
overlay=""
[ -n "$mem_part" ]           && overlay="${mem_part}"
[ -n "$boot_status_themed" ] && overlay="${overlay:+${overlay} }${boot_status_themed}"
[ -n "$skip_themed" ]        && overlay="${overlay:+${overlay} }${skip_themed}"
[ -n "$overlay" ]            && cont_display="${sep}${overlay}"

printf "$(ansi_fg "$THEME_FG_PWD")%s${RESET}%b ${pill}%b%b\n" \
  "${ICON_PWD}${ICON_PWD:+ }${dir}" "$vibe_part" "$git_part" "$cont_display"

# --- Line 2 ---
parts=""
if [ -n "$ctx" ] && [ "$ctx" != "0" ]; then
  parts="$(format_pct "$(ansi_fg "$THEME_FG_CTX_ICON")${ICON_CTX}${RESET} ctx" "$ctx")"
fi
if [ -n "$five_h" ]; then
  [ -n "$parts" ] && parts="${parts}${sep}"
  parts="${parts}$(format_pct "$(ansi_fg "$THEME_FG_5H_ICON")${ICON_5H}${RESET} 5h" "$five_h" "$five_h_reset" 80 90)"
fi
if [ -n "$seven_d" ]; then
  [ -n "$parts" ] && parts="${parts}${sep}"
  seven_d_warn=80
  if [ -n "$seven_d_reset" ]; then
    days_left=$(( (seven_d_reset - $(date +%s)) / 86400 ))
    [ "$days_left" -lt 0 ] && days_left=0
    [ "$days_left" -gt 7 ] && days_left=7
    days_elapsed=$(( 7 - days_left ))
    seven_d_warn=$(( days_elapsed * 100 / 7 ))
    [ "$seven_d_warn" -lt 14 ] && seven_d_warn=14
  fi
  parts="${parts}$(format_pct "$(ansi_fg "$THEME_FG_7D_ICON")${ICON_7D}${RESET} 7d" "$seven_d" "$seven_d_reset" "$seven_d_warn" 90 10)"
fi
[ -n "$parts" ] && printf "%b\n" "$parts"

# --- Line 3: turn-rate sparkline (full + medium only) ---
if [ "$mode" != "narrow" ]; then
  TOKEN_LOG="$HOME/.claude/statusline-token-rate.log"
  if [ -f "$TOKEN_LOG" ] && [ -n "$session_id" ]; then
    deltas=$(mp_sparkline_data "$TOKEN_LOG" "$session_id")
    if [ -n "$deltas" ]; then
      bars=$(mp_sparkline_render "$deltas")
      if [ "$mode" = "full" ]; then
        # "last" + "peak" stats next to the bars.
        last=$(printf '%s' "$deltas" | awk '{printf "%d", $NF}')
        peak=$(printf '%s' "$deltas" | awk '{ m=0; for(i=1;i<=NF;i++) if ($i+0 > m) m=$i+0; printf "%d", m }')
        last_s=$(awk -v n="$last" 'BEGIN { if (n >= 1000000) printf "%.1fM", n/1000000; else if (n >= 1000) printf "%.1fK", n/1000; else printf "%d", n }')
        peak_s=$(awk -v n="$peak" 'BEGIN { if (n >= 1000000) printf "%.1fM", n/1000000; else if (n >= 1000) printf "%.1fK", n/1000; else printf "%d", n }')
        # NOTE: double quotes around the format string so ${RESET} expands.
        # printf then interprets the \033 escapes in the format.
        printf "\033[2mturn${RESET} %b  \033[2mlast${RESET} %s \033[2m·${RESET} \033[2mpeak${RESET} %s\n" "$bars" "$last_s" "$peak_s"
      else
        printf '%b\n' "$bars"
      fi
    fi
  fi
fi
```

(Delete the original lines ~276-317 that this replaces.)

- [ ] **Step 4: Run, verify it passes**

```bash
bash tests/test_statusline_render.sh
```

Expected: `ALL PASS` on the full-mode assertions.

- [ ] **Step 5: Run the whole suite to confirm nothing else regressed**

```bash
for t in tests/test_*.sh;  do bash "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done
for t in tests/test_*.mjs; do node "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done
```

Expected: every test PASS.

- [ ] **Step 6: Mutation check**

Temporarily change the pill section to drop the background color:

```sh
pill="$(ansi_fg "$pill_fg") ${pill_label} ${RESET}"
```

Re-run. Expected: FAIL with `full mode: model pill renders truecolor bg`.

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add statusline-command.sh tests/test_statusline_render.sh tests/fixtures/statusline-stdin-full.json
git commit -m "feat(statusline): wire helpers; full-mode 3-line render with pill + sparkline"
```

---

## Task 13: Medium-mode rendering assertions

**Files:**
- Modify: `tests/test_statusline_render.sh` (add medium-mode snapshot)

The medium-mode logic is already in `statusline-command.sh` (`mp_width_mode` + the conditional drops in `format_pct` and line 3). This task verifies it behaves correctly via the test surface.

- [ ] **Step 1: Add medium-mode assertions**

Append to `tests/test_statusline_render.sh` BEFORE the final `echo "----"`:

```bash
# ─── statusline-command.sh integration: medium mode ───────────────────────
if [ -f "$SL" ]; then
  out=$(COLUMNS=72 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX/statusline-stdin-full.json" 2>/dev/null)

  lc=$(printf '%s' "$out" | wc -l | tr -d ' ')
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
```

- [ ] **Step 2: Run, verify it passes**

```bash
bash tests/test_statusline_render.sh
```

Expected: `ALL PASS`. If a medium-mode assertion FAILS, the bug is in Task 12's rendering block — fix it there, NOT here.

- [ ] **Step 3: Mutation check**

Temporarily change `[ "$mode" = "medium" ] && bar_width=6` to `bar_width=8` in `format_pct`. Re-run.

Expected: FAIL with `medium mode: bar width = 6 per segment`.

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 4: Commit**

```bash
git add tests/test_statusline_render.sh
git commit -m "test(statusline): medium-mode behavior assertions"
```

---

## Task 14: Narrow-mode rendering assertions

**Files:**
- Modify: `tests/test_statusline_render.sh` (add narrow-mode snapshot)

- [ ] **Step 1: Add narrow-mode assertions**

Append to `tests/test_statusline_render.sh` BEFORE the final `echo "----"`:

```bash
# ─── statusline-command.sh integration: narrow mode ───────────────────────
if [ -f "$SL" ]; then
  out=$(COLUMNS=48 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX/statusline-stdin-full.json" 2>/dev/null)

  lc=$(printf '%s' "$out" | wc -l | tr -d ' ')
  [ "$lc" = "2" ] && ok "narrow mode: 2 lines (no sparkline)" \
    || bad "narrow mode: 2 lines (no sparkline)" "got $lc; out: $out"

  # No sparkline glyphs anywhere.
  if echo "$out" | grep -qE '[▁▂▃▄▅▆▇█]'; then
    bad "narrow mode: no sparkline glyphs"
  else
    ok "narrow mode: no sparkline glyphs"
  fi

  # No 7d countdown (↻Xd) since reset_str dropped in narrow.
  # No bars on 5h / 7d (just percentages).
  bar_chars=$(echo "$out" | sed -n '2p' | grep -oE '[▓░]' | wc -l | tr -d ' ')
  [ "$bar_chars" = "0" ] && ok "narrow mode: no bars (just %)" \
    || bad "narrow mode: no bars" "got $bar_chars bars"

  # Boot indicator still present (silent-amnesia signal, never dropped).
  # We need a marker file for this — set one up.
  HOOKS_TEST_DIR="$HERE/../hooks"
  marker="$HOOKS_TEST_DIR/.boot-marker-test-session-full"
  echo "loaded" > "$marker"
  trap 'rm -rf "$TMPHOME" "$TMPLOG" "$marker"' EXIT
  out2=$(COLUMNS=48 HOME="$TMPHOME" MEMORY_PACK_NERDFONT=0 bash "$SL" < "$FIX/statusline-stdin-full.json" 2>/dev/null)
  echo "$out2" | grep -q 'booted' \
    && ok "narrow mode: boot indicator (✓booted) preserved" \
    || bad "narrow mode: boot indicator preserved" "out2: $out2"

  # Model pill still present (drives narrow label form).
  echo "$out2" | head -n 1 | grep -q 'opus' \
    && ok "narrow mode: pill label compacted to 'opus'" \
    || bad "narrow mode: pill label compacted to 'opus'" "got: $(echo "$out2" | head -1)"
fi
```

- [ ] **Step 2: Run, verify it passes**

```bash
bash tests/test_statusline_render.sh
```

Expected: `ALL PASS`. If anything fails, fix in `statusline-command.sh`'s narrow branch.

- [ ] **Step 3: Mutation check**

Temporarily comment out the `[ "$mode" = "narrow" ] && pill_label=$(...)` block. Re-run.

Expected: FAIL with `narrow mode: pill label compacted to 'opus'` (now shows the full `claude-opus-4-7`-derived label).

Revert. Re-run. Expected: `ALL PASS`.

- [ ] **Step 4: Commit**

```bash
git add tests/test_statusline_render.sh
git commit -m "test(statusline): narrow-mode behavior assertions"
```

---

## Task 15: Final integration sweep + full-suite GREEN

**Files:**
- (none — verification only)

- [ ] **Step 1: Run the entire test suite**

```bash
cd /Users/namhp/Resilio.Sync/Memory.Pack
for t in tests/test_*.sh;  do bash "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done
for t in tests/test_*.mjs; do node "$t" >/dev/null 2>&1 && echo "PASS $t" || echo "FAIL $t"; done
```

Expected: every test PASS. The 14 expected suites are now (was 11):

1. `tests/test_hash_shim.sh`
2. `tests/test_hooks_wired.sh`
3. `tests/test_install.sh`
4. `tests/test_inject_preamble_epistemic.mjs`
5. `tests/test_log_token_rate.sh`           ← new
6. `tests/test_mph_resolution.sh`
7. `tests/test_nerdfont_helper.sh`          ← new
8. `tests/test_path_portability.mjs`
9. `tests/test_recall_frontmatter_preserve.mjs`
10. `tests/test_sdk_resolve.mjs`
11. `tests/test_settings_merge.sh`
12. `tests/test_slug_anchored_to_transcript_path.sh`
13. `tests/test_statusline_marker_path.sh`
14. `tests/test_statusline_render.sh`       ← new

If any test FAILS, fix the underlying code (NOT the test) before proceeding.

- [ ] **Step 2: Render the statusline against a live fixture and inspect output**

```bash
COLUMNS=200 HOME="$(pwd)" bash statusline-command.sh < tests/fixtures/statusline-stdin-full.json | cat -v
```

You should see three lines of escaped ANSI (`^[[38;2;…m`) with the pill, ctx/5h/7d bars, and sparkline glyphs.

```bash
COLUMNS=72 HOME="$(pwd)" bash statusline-command.sh < tests/fixtures/statusline-stdin-full.json | cat -v
```

Three lines, narrower bars, no "last/peak" labels.

```bash
COLUMNS=48 HOME="$(pwd)" bash statusline-command.sh < tests/fixtures/statusline-stdin-full.json | cat -v
```

Two lines, no sparkline.

- [ ] **Step 3: Update CLAUDE.md test inventory** (if needed)

`CLAUDE.md` references "11 suites in `tests/`". Update to:

> 14 suites in `tests/` — run all before any commit

And in the test enumeration paragraph, add brief entries for `test_log_token_rate`, `test_nerdfont_helper`, and `test_statusline_render`.

- [ ] **Step 4: Commit the CLAUDE.md update**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md test inventory (11 → 14 suites)"
```

- [ ] **Step 5: Final sanity — fresh statusline render in a real terminal**

Open a fresh terminal at the repo, ensure your shell has `COLUMNS` exported, and let the live statusline render via CC. Confirm visually:

- Line 1: working dir + (any vibe tag) + model pill + git branch + memory + boot indicator
- Line 2: ctx/5h/7d with theme'd RGB bars and countdowns
- Line 3: sparkline of recent token-rate samples (will populate after Stop hook fires a few times)

The first session's sparkline line will be empty (no log file yet) — that's expected; appears once `~/.claude/statusline-token-rate.log` has ≥ 2 samples for this session_id.

---

## Self-review

Cross-checking the plan against the spec:

| Spec requirement | Task |
|---|---|
| D1 substrate: POSIX sh + awk | every task (no Python or Node added) |
| D2 turn-based sparkline, last 16 | Task 6 (`mp_sparkline_data` caps at 16), Task 8 (writer) |
| D3 3-line layout | Task 12 (full), Task 13 (medium), Task 14 (narrow drops line 3) |
| D4 single fixed theme, structured for expansion | Task 2 (`statusline-theme.sh`) |
| D5 hybrid Nerd Font auto-detect | Task 1 (`_mp_have_nerdfont`), Task 3 (`statusline-icons.sh`) |
| D6 width breakpoints 80/55 | Task 7 (`mp_width_mode`) |
| D7 snake↔camel fix | Task 11 (statusline) + Task 8 (new hook) |
| Per-model identity pill | Task 4 (`mp_pill_fg`), Task 12 (model→anchor lookup) |
| Themed RGB palette | Task 2 (theme), Task 4-6 (consumers) |
| Width-adaptive layout | Task 7 (mode), Task 12-14 (per-mode behavior) |
| New hook `log-token-rate.sh` | Task 8 |
| Registration count 11 → 12 | Task 9 |
| Runtime-state recognition for new log | Task 10 |
| Never-drop signals (boot, skip-replay, vibe, 🧠 count) | Task 12 (full+medium), Task 14 (narrow assertion preserves boot) |
| Race-tolerant Stop hook | Task 8 (jq tail + empty → exit 0) |
| Test surface: render, log_token_rate, pill_luminance | Tasks 4 (pill subsumed into render), 6, 8 |
| Mutation checks throughout | every task has a Step "Mutation check" |

**Spec coverage gaps:** none — every D-numbered decision and every "files affected" entry has a task.

**Placeholder scan:** every code block contains the actual code an engineer would paste. No "TBD" / "implement later" / "similar to Task N". The `mp_sparkline_data` and `mp_gradient_color` awk one-liners are fully written out.

**Type consistency:** function names and var names cross-check:
- `mp_pill_fg`, `mp_gradient_color`, `mp_sparkline_data`, `mp_sparkline_render`, `mp_width_mode`, `_mp_have_nerdfont` — referenced consistently in tests and source.
- `THEME_*` var names match between `statusline-theme.sh`, the schema test in Task 2, and the consumers in Tasks 4-6.
- `ICON_*` var names match between `statusline-icons.sh` and the icons test in Task 3.
- Hook stdin field names (snake + camel) match between Task 11's assertions and Task 12's rewrite.

**Scope check:** one implementation plan covers the full spec. No subsystem extraction needed.

---

## Files affected (recap)

Added:

- `hooks/statusline-theme.sh`
- `hooks/statusline-icons.sh`
- `hooks/statusline-render.sh`
- `hooks/log-token-rate.sh`
- `tests/test_nerdfont_helper.sh`
- `tests/test_statusline_render.sh`
- `tests/test_log_token_rate.sh`
- `tests/fixtures/transcript-with-usage.jsonl`
- `tests/fixtures/transcript-no-assistant.jsonl`
- `tests/fixtures/statusline-stdin-full.json`

Modified:

- `hooks/_lib.sh` — `+_mp_have_nerdfont`
- `install/hooks.manifest.json` — `+1 entry`
- `install.sh` — EXCL list + Nerd Font tip
- `.gitignore` — `statusline-token-rate.log`
- `statusline-command.sh` — render-block rewrite + snake↔camel stdin fix
- `tests/test_settings_merge.sh` — count 11 → 12, regex update
- `tests/test_install.sh` — count 11 → 12
- `tests/test_mph_resolution.sh` — runtime-state scan
- `CLAUDE.md` — test inventory 11 → 14
