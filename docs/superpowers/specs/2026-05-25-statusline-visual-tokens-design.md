# Statusline visual-token redesign

**Date:** 2026-05-25
**Inspiration:** [`tmck-code/yet-another-statusline`](https://github.com/tmck-code/yet-another-statusline) (YAS) — visual aesthetic only; we are not porting code.
**Substrate:** POSIX `sh` + `awk` (no Python port, no Node helper).
**Status:** approved by user; implementation plan pending.

## Summary

Today's `statusline-command.sh` is a 317-line POSIX `sh` script that prints two lines: directory + vibe + model + git on line 1, and ctx% / 5h% / 7d% bars on line 2, with continuity overlays (`✓booted`, `🧠 NN/150`, `⏭skip-replay`). It uses 16-color ANSI only and has no per-model identity, no token-rate trend, and no width-adaptive layout.

This redesign keeps every existing signal, fixes one latent bug, and adds four visual elements inspired by YAS:

1. **Per-model identity pill** (line 1) — colored badge with per-cell luminance-flipped foreground.
2. **Token-rate sparkline** (line 3) — turn-based, last 16 turns, green→yellow→orange→red→purple gradient.
3. **Themed RGB palette** — one fixed dark theme, all colors sourced from `hooks/statusline-theme.sh` as truecolor (`\033[38;2;R;G;Bm`).
4. **Width-adaptive layout** — full / medium / narrow rendering by `${COLUMNS:-80}`.

The script grows from ~317 to ~600 lines. One new hook is added (`hooks/log-token-rate.sh`, registered on `Stop`). Hook registration count goes 11 → 12.

## Locked decisions

| # | Decision | Rejected alternatives |
|---|---|---|
| D1 | Substrate stays POSIX `sh` + `awk`; no Python port; no Node helper | Full Python port (YAS-shaped); hybrid sh + python3 render helper |
| D2 | Sparkline is **turn-based** (1 bar per Stop fire, last 16) | YAS-style time-based 30-bucket / 60s window; skip sparkline entirely |
| D3 | Layout is **3 lines** (line 1 + line 2 + sparkline line) | 2 lines with 7d compressed; 2 lines with 7d dropped |
| D4 | **One fixed dark theme** in `hooks/statusline-theme.sh`, structured for future expansion | 2-3 selectable themes via env; full YAS-style CLI/env/config precedence |
| D5 | **Hybrid Nerd Font** via `MEMORY_PACK_NERDFONT=1` env override + `fc-list` auto-detect; falls back to current Unicode glyphs | Hard Nerd Font dependency; pure Unicode (no Nerd Font support at all) |
| D6 | Width breakpoints: **full > 80, medium 56–80, narrow ≤ 55** (columns, not pixels — YAS README typo) | — |
| D7 | snake↔camel stdin fallback applied to **every** `jq -r` field read | Keep snake-only (preserves invariant #3 latent bug; scoped out of prior PR) |

D7 is a deliberate scope expansion of one line that was deferred in a prior PR (`statusline-command.sh:14`). Including it here is incidental, not surrounding cleanup — this rewrite touches that exact line.

## Layout specification

### Full mode (cols > 80)

```
<dir> ⚡<vibe> <pill:model> <git-icon><branch>±<dirty> +N/-M │ <mem-icon> NN/150 KKB <boot> <skip>
<ctx-icon> ctx NN% ▓▓░░░░░░░░ │ <5h-icon> 5h NN% ▓▓▓▓░░░░░░ ↻Xh │ <7d-icon> 7d NN% ▓░░░░░░░░░ ↻Xd
turn ▁▂▂▃▄▆█▇▅▄▃▂▂▁▁▁  last NN.NK · peak NNNK
```

### Medium mode (cols 56–80)

- Drop sparkline labels (`last`/`peak` numerics)
- Drop 7d reset countdown (`↻Xd`)
- Reduce bar widths from 10 chars to 6
- Keep all three lines

### Narrow mode (cols ≤ 55)

- Drop line 3 (sparkline) entirely
- Collapse 5h and 7d to bare `<pct>%` (no bar, no countdown)
- Drop `+N/-M` git line-count
- Drop memory size in KB (keep `NN/150` line count only)

### Never-drop signals (silent-amnesia class)

These render in every mode at every width — they are the engine's reason for existing:

- Boot indicator: `✓booted` / `⏳pending` / `⚠replay-err`
- `⏭skip-replay` sentinel
- `🧠 NN/150` MEMORY.md headroom (line count; KB is droppable, count is not)
- Vibe tag (`⚡<vibe>`) — workspace-set, never lost to width

## Component map

| File | Status | Role |
|---|---|---|
| `statusline-command.sh` | rewritten in place | Entry point. Reads CC stdin, sources theme + icons, renders 2-3 lines. |
| `hooks/statusline-theme.sh` | NEW | Sourced shell file exporting `THEME_*` vars (RGB tuples + ANSI escape helpers). v1 ships `claude-dark`-flavored values only. |
| `hooks/statusline-icons.sh` | NEW | Sourced shell file exporting `ICON_*` vars after running `_mp_have_nerdfont` to choose `ICONS_NERD_*` or `ICONS_UNICODE_*` tables. |
| `hooks/log-token-rate.sh` | NEW | Stop-hook. Tails `transcript_path`, extracts assistant `usage`, appends cumulative-token line to log. Race-tolerant. |
| `hooks/_lib.sh` | edit | Add `_mp_have_nerdfont` helper. |
| `install/hooks.manifest.json` | edit | Add `Stop → log-token-rate.sh` registration (count 11 → 12). |
| `~/.claude/statusline-token-rate.log` | NEW (runtime) | Append-only log; format `<epoch> <session_id> <cum_tokens>` per Stop fire. Lives in `~/.claude/`, not repo. |

## Data flow

### Statusline render (per CC invocation)

1. Read JSON from stdin.
2. Extract fields via `jq -r '.workspace.project_dir // .workspace.projectDir // empty'` pattern for every field (snake↔camel).
3. `source hooks/statusline-theme.sh` → `THEME_FG_PWD`, `THEME_PILL_OPUS_ANCHOR`, `THEME_GRAD_STOPS`, etc.
4. `source hooks/statusline-icons.sh` → `ICON_BRANCH`, `ICON_DIRTY`, `ICON_BOOT_OK`, etc. (already font-resolved).
5. `cols=${COLUMNS:-80}`; choose full/medium/narrow.
6. Compute segments (dir, vibe, pill, git, memory, boot/skip, ctx, 5h, 7d). Existing math reused; pill is new (luminance-flip awk one-liner); bar colors come from theme vars.
7. For full + medium: read last 16 lines matching `session_id` from `~/.claude/statusline-token-rate.log`, compute per-turn deltas with `awk`, scale to max, color each bar by ratio against `THEME_GRAD_STOPS`.
8. `printf` 2 or 3 lines.

### Hook write (per Stop fire)

```sh
# log-token-rate.sh — pseudocode
input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // .sessionId // empty')
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // .transcriptPath // empty')
[ -z "$transcript" ] || [ ! -f "$transcript" ] && exit 0

usage=$(tail -n 50 "$transcript" 2>/dev/null \
  | jq -c 'select(.type=="assistant") | .message.usage' 2>/dev/null \
  | tail -n 1)
[ -z "$usage" ] && exit 0   # race-tolerant: next Stop catches up

cum=$(printf '%s' "$usage" | jq -r '
  (.input_tokens // 0) +
  (.cache_creation_input_tokens // 0) +
  (.cache_read_input_tokens // 0) +
  (.output_tokens // 0)
')
printf '%s %s %s\n' "$(date +%s)" "$session_id" "$cum" >> "$HOME/.claude/statusline-token-rate.log"
```

POSIX `>>` is atomic for sub-PIPE_BUF writes (one line is well under 4 KB). No locking needed.

## Theme schema

`hooks/statusline-theme.sh` exports the following (all values are RGB tuples as `"R G B"` strings or ANSI escape sequences):

```
THEME_FG_PWD            # foreground for working dir
THEME_FG_BRANCH         # git branch text
THEME_FG_DIRTY          # dirty-tree marker
THEME_FG_LINES_ADD      # +NN git line count
THEME_FG_LINES_DEL      # -NN git line count
THEME_FG_MEMORY_OK      # 🧠 in safe zone
THEME_FG_MEMORY_WARN    # 🧠 in soft-cap zone
THEME_FG_MEMORY_CRIT    # 🧠 in hard-cap zone
THEME_FG_BOOT_OK        # ✓booted
THEME_FG_BOOT_PENDING   # ⏳pending
THEME_FG_BOOT_ERR       # ⚠replay-err
THEME_FG_SKIP_REPLAY    # ⏭skip-replay
THEME_FG_VIBE           # ⚡<vibe>
THEME_FG_CTX_ICON       # ◐
THEME_FG_5H_ICON        # ⏱
THEME_FG_7D_ICON        # ⏳
THEME_BAR_FILL_SAFE     # ▓ in safe zone (3-step ladder)
THEME_BAR_FILL_WARN     # ▓ in warn zone
THEME_BAR_FILL_ALERT    # ▓ in alert zone
THEME_BAR_EMPTY         # ░ background
THEME_PILL_OPUS_ANCHOR  # opus pill bg RGB
THEME_PILL_SONNET_ANCHOR
THEME_PILL_HAIKU_ANCHOR
THEME_PILL_OTHER_ANCHOR
THEME_PILL_FG_DARK      # used when bg luminance Y >= 128
THEME_PILL_FG_LIGHT     # used when bg luminance Y <  128
THEME_GRAD_STOPS        # "0.00:40,210,80 0.25:240,230,20 0.50:255,140,20 0.75:220,40,50 1.00:170,60,210"
```

Adding a sibling theme later: drop a file with the same var names + a `THEME_NAME=...` line, ship a resolver in v2.

## Icon schema (hybrid Nerd Font)

`hooks/statusline-icons.sh` defines two tables, picks one via `_mp_have_nerdfont`:

```
# After resolution, these are the live values used by statusline-command.sh:
ICON_BRANCH       #  (Nerd) or  (Unicode)
ICON_DIRTY        #  (Nerd) or * (Unicode)
ICON_PWD          #  (Nerd) or '' (Unicode — dir name alone)
ICON_MEMORY       #  (Nerd) or 🧠 (Unicode)
ICON_BOOT_OK      #  (Nerd) or ✓ (Unicode)
ICON_BOOT_PENDING #  (Nerd) or ⏳ (Unicode)
ICON_BOOT_ERR     #  (Nerd) or ⚠ (Unicode)
ICON_SKIP_REPLAY  #  (Nerd) or ⏭ (Unicode)
ICON_CTX          # 󰍉 (Nerd) or ◐ (Unicode)
ICON_5H           #  (Nerd) or ⏱ (Unicode)
ICON_7D           # 󰪠 (Nerd) or ⏳ (Unicode)
ICON_VIBE         #  (Nerd) or ⚡ (Unicode)
```

`_mp_have_nerdfont` in `hooks/_lib.sh`:

```sh
_mp_have_nerdfont() {
    case "${MEMORY_PACK_NERDFONT:-}" in
        1|true|yes) return 0 ;;
        0|false|no) return 1 ;;
    esac
    command -v fc-list >/dev/null 2>&1 || return 1
    fc-list :family | grep -qi 'nerd'
}
```

`install.sh` prints a one-line tip when no Nerd Font detected: `Tip: install a Nerd Font (https://www.nerdfonts.com) for richer statusline icons, or set MEMORY_PACK_NERDFONT=1 to opt in anyway.`

## Error handling

| Failure mode | Effect | Boundary |
|---|---|---|
| `~/.claude/statusline-token-rate.log` missing | Sparkline line omitted (same as medium-mode collapse) | acceptable |
| `jq -c` returns empty on Stop hook (assistant entry not yet flushed) | Hook exits 0 silent; next Stop catches up via cumulative count | acceptable |
| Empty `transcript_path` in Stop stdin | Hook exits 0 silent | acceptable (matches existing snake↔camel guards) |
| `awk` math failure in statusline render | `|| true` guards; remaining lines still print | acceptable |
| `MEMORY_PACK_NERDFONT=1` set but no font installed | Nerd glyphs render as tofu | acceptable (user opt-in wins) |
| Boot indicator missing from line 1 | **Never acceptable** — silent-amnesia signal; gated by neither width nor theme | hard rule |

## Invariant preservation

From [`CLAUDE.md`](../../../CLAUDE.md#invariants-that-must-not-regress) — the five silent-amnesia-class invariants:

| # | Invariant | Status |
|---|---|---|
| 1 | `_mp_hash` value-preservation | UNTOUCHED |
| 2 | statusline parity (`mp_proj_hash` byte-identical to `_mp_hash`) | UNTOUCHED — helper unchanged |
| 3 | snake↔camel stdin | **FIXED** — every `jq -r` field read gains a camelCase fallback (resolves latent bug at `statusline-command.sh:14`) |
| 4 | project slug + `mp_resolve_project_key` | UNTOUCHED — helper unchanged |
| 5 | runtime state never packaged | `statusline-token-rate.log` is a runtime artifact, lives in `~/.claude/`, NOT in repo. `.gitignore` + `install.sh` EXCL + `tests/test_mph_resolution.sh` runtime-state scan all updated to recognize it as derived/ephemeral. |

## Test surface

All tests follow Memory.Pack TDD discipline: failing test first → watch RED → minimal GREEN → mutation check (corrupt → re-fail → revert).

### New tests

- `tests/test_statusline_render.sh` — behavioral subprocess (per `test_install.sh` idiom). Pipes 5 fixture stdins through the script under `COLUMNS=N` env override; snapshot-diffs the output:
  - full mode, all signals present
  - medium mode, no countdown
  - narrow mode, line 3 dropped
  - no token-rate log present → sparkline line omitted gracefully
  - missing rate_limits fields → 5h/7d segments omitted
  Mutation: tweak one snapshot character → assert failure.

- `tests/test_log_token_rate.sh` — behavioral subprocess. Synthesizes a fixture transcript jsonl + Stop stdin; asserts the log line lands with correct format. Mutation: omit the assistant entry from the fixture → assert NO log line written (race-tolerant branch).

- `tests/test_pill_luminance_flip.sh` — value-pinned `awk` math. Known RGB anchors → assert dark-fg or light-fg chosen per Y < 128 / Y ≥ 128. Mutation: flip the threshold → fail.

### Updated tests

- `tests/test_hooks_wired.sh` — hook registration count 11 → 12; expects `log-token-rate.sh` registered on `Stop`.
- `tests/test_install.sh` — `.gitignore` and `install.sh` EXCL list both include `statusline-token-rate.log`.
- `tests/test_mph_resolution.sh` — runtime-state scan recognizes the new log as derived/ephemeral (never packaged).
- `tests/test_settings_merge.sh` — verifies `log-token-rate.sh` registration merges/unmerges cleanly alongside the existing `auto-save-stop.sh` Stop hook.

### Regression gates (must keep passing)

- `tests/test_hash_shim.sh` — `mp_proj_hash` math unchanged
- `tests/test_statusline_marker_path.sh` — reader↔writer marker-path parity (invariant #2)
- `tests/test_slug_anchored_to_transcript_path.sh` — `mp_resolve_project_key` parity (invariant #4)
- `tests/test_recall_frontmatter_preserve.mjs`, `tests/test_inject_preamble_epistemic.mjs`, `tests/test_path_portability.mjs`, `tests/test_sdk_resolve.mjs` — engine surface untouched

## Out of scope (deferred)

- **Theme runtime selection.** v1 ships one fixed theme. Var-name schema is forward-compatible — a v2 sibling theme is a file drop + a resolver.
- **Log rotation.** No v1 cron. Reader filters by session_id + tails last 16 lines; old session entries are inert. Deferred until file size becomes a problem.
- **Multi-session combined sparkline.** YAS has it; we are single-session at the statusline level.
- **Pixel-based width breakpoints.** YAS README mentions pixels but the implementation reads `COLUMNS` (a column count). We use the same. Close enough for monospace.
- **The 12 named decorative gradients** (Ocean, Sunset, Forest, …) from YAS's `spec_gradients`. They power YAS's OpenSpec progress rows — a feature we don't have. Re-add when a consumer feature emerges. If you want them shipped in `hooks/statusline-theme.sh` anyway as forward-compatible data, raise on spec review.
- **Click-through OSC 8 links** (e.g. clickable git branch → GitHub). YAS supports it; doable later in `hooks/statusline-icons.sh` per CC's clickable-links docs.

## Files affected (summary)

```
A  hooks/log-token-rate.sh
A  hooks/statusline-theme.sh
A  hooks/statusline-icons.sh
A  tests/test_statusline_render.sh
A  tests/test_log_token_rate.sh
A  tests/test_pill_luminance_flip.sh
A  tests/fixtures/statusline-*.json         # 5+ fixture stdins
A  tests/fixtures/transcript-*.jsonl        # 2 fixture transcripts
A  docs/superpowers/specs/2026-05-25-statusline-visual-tokens-design.md  (this file)
M  statusline-command.sh                    # ~317 → ~600 lines
M  hooks/_lib.sh                            # +_mp_have_nerdfont
M  install/hooks.manifest.json              # +1 registration
M  install.sh                               # EXCL list + Nerd Font tip
M  .gitignore                               # statusline-token-rate.log, .superpowers/
M  tests/test_hooks_wired.sh                # count 11 → 12
M  tests/test_install.sh                    # gitignore + EXCL assertions
M  tests/test_mph_resolution.sh             # runtime-state scan
M  tests/test_settings_merge.sh             # Stop hook merge/unmerge
```
