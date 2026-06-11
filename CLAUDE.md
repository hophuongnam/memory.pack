# Memory.Pack — engine dev/maintenance guide

Session-continuity + auto-memory engine for Claude Code. Git repo
(`github.com/hophuongnam/memory.pack`, branch `main`), wired globally from
`~/.claude/settings.json` — hooks run by **absolute path**, never symlinked
per-project. `hooks/` is the single source of truth. `statusline-command.sh`
(repo root) is the one symlinked artifact: `~/.claude/statusline-command.sh`
→ here, invoked through that symlink by settings.json `statusLine.command`.
This project owns its development (relocated out of the Management project
2026-05-18); `install.sh` wires the symlink + `.statusLine` on any host.

## Working style (this project)

- Radical candor. Don't flatter. Tell me what I need to hear, including when
  a design is wrong or a "fix" is actually a regression.
- Research-first, then surgical edits. Read the actual code/`SCHEMA.md`
  before changing behavior — never reason from assumptions.
- **TDD is non-negotiable here.** Every change (feature or bugfix):
  failing test first → watch it fail for the right reason → minimal GREEN.
  The engine's failure mode is *silent amnesia* — a regression is invisible
  until a future session boots empty, so tests are the only safety net.
- This project has its own auto-memory store
  (`~/.claude/projects/-Users-namhp-Resilio-Sync-Memory-Pack/memory/`).
  Engine architecture + lessons live there (`project_memory_pack_engine.md`
  + `feedback_*`/`reference_*`). Read `SCHEMA.md` for the memory contract.

## Architecture

**12 hook registrations** (canonical list: `install/hooks.manifest.json`):
`SessionStart`→boot-inject; `UserPromptSubmit`→boot-inject + memory-search-inject;
`SessionEnd`→session-end + memory-index-reconcile; `Stop`→auto-save-stop +
log-token-rate; `PostToolUse` Read→memory-recall, Write→archive-resurrect +
memory-index-update, Edit/MultiEdit→memory-index-update.

**Two-pass replay** (`hooks/replay.mjs`, detached by `session-end.sh` via
`nohup`/`disown`; model `claude-sonnet-4-6`, `maxTurns:6`, `tools:[]`):
pass 1 → `.boot-context-<hash>` (consumed once by `boot-inject.sh`, archived
to `sessions.log.md` + `SESSIONS.md`); pass 2 → strict "default NONE"
promotion agent appends to `PENDING_MEMORIES.md` (proposes, never writes —
runs detached without read access to memory bodies). Transcript text comes
from `_lib.mjs extractConversation` (skips isMeta + tool_result user
entries, accepts string AND array-text prompts) bounded by
`truncateConversation` (head+tail ≈200k chars — a long session must not
blow the prompt and lose its summary). Exit codes: 0 ok, 2 benign no-op,
3 real failure (session-end synthesizes a self-reporting "Replay failed"
boot-context embedding the per-project `.replay-error-<hash>.log` tail).
The detached launcher passes every dynamic value via `env` into a STATIC
single-quoted body — interpolation was a parse error for quoted project
paths (silent amnesia for `Nam's Proj`-style dirs).

**Memory-write split (4 ways):** (a) `auto-save-stop.sh` blocks every
`SAVE_INTERVAL=50` REAL user turns (`_mp_real_user_turns` in `_lib.sh`:
tool_results, isMeta bookkeeping, and slash-command entries excluded — raw
`"type":"user"` counting fired after ~50 transcript ENTRIES ≈ a handful of
real turns; same counter feeds session-end's trivial-replay skip, which
skips only when turns ≤5 AND the session is small on BOTH substance axes:
`_mp_conversation_chars` < `MP_REPLAY_MIN_CHARS` (25k) AND raw transcript
< `MP_REPLAY_MIN_BYTES` (200KB) — a 2-prompt session can be a 2MB
autonomous monster worth replaying, and tool-heavy monsters hold few
conversation chars so BOTH axes are load-bearing; 0-turn headless
sessions always skip)
→ Claude writes bodies. (b) `boot-inject.sh`
writes `sessions.log.md`/`SESSIONS.md`. (c) `replay.mjs` pass 2 writes
`PENDING_MEMORIES.md`. (d) `memory-recall.sh`→`update-recall.mjs` edits
*frontmatter only* (recall_count/last_recalled), session-deduped, and
auto-promotes archived→active at `recall_count>=3`. The CC harness
auto-stamps `originSessionId` on every memory Write/Edit — legitimate,
never strip it.

**FTS5 search** (`index/`): `index-memories.py` walks all
`~/.claude/projects/*/memory/**/*.md` → SQLite `search.db` (gitignored,
derived, rebuilt at install — never packaged). `search-memories.py` =
BM25 CLI behind the `memory-search` skill. `memory-search-inject.sh`
auto-injects ≤3 prompt-relevant hits per UserPromptSubmit (bash+jq+sqlite3,
~30ms; threshold + coverage filtered). Index is cross-project by design.

**`SCHEMA.md`** (repo root) is THE canonical memory contract for every
project store — types, frontmatter, decay model. No per-project copy.

## Invariants that MUST NOT regress (silent-amnesia class)

1. **`_mp_hash` value-preservation** (`hooks/_lib.sh`). Order
   `md5sum→md5→python3→loud-fail` is a *latency* choice only; the value is
   byte-identical across every branch (MD5 is MD5) and equals the live
   on-disk sentinels (e.g. project key `…/Management` → `3bfed408`). Never
   value-depend on which tool ran; never collapse the shim (bare
   `md5|head -c8` produced an empty `PROJECT_HASH` on Linux → silent
   boot-context amnesia — the reason this exists); never reorder so python3
   precedes md5sum/md5 (it sits on boot-inject's pre-marker race path).
2. **statusline parity.** `statusline-command.sh`'s (repo root)
   `mp_proj_hash` must stay value-equal to `_mp_hash` or `⏭skip-replay`
   targets the wrong sentinel. `test_hash_shim` proves this in-repo
   (resolves the script off `$HERE`, never a hard-coded path).
3. **snake↔camel hook stdin.** Every hook parsing CC stdin must accept
   both `session_id`/`sessionId`, `hook_event_name`/`hookEventName`, etc.,
   or marker/boot-context writes silently no-op across CC releases.
4. **Project slug** must mirror CC's `~/.claude/projects/<slug>` naming
   (abs cwd, `/`+`.`→`-`) identically in `boot-inject.sh`, `replay.mjs`,
   and `index-memories.py`, or memories mis-file. PROJECT_KEY is resolved
   via `_mp_resolve_project_key` (`_lib.sh`) — anchor to CC's per-session
   slug (`basename(dirname(transcript_path))`) and walk up the
   workspace/cwd ancestor whose `[/.]→-` slugification matches. The bare
   `${PROJECT_DIR:-${CWD:-$PWD}}` chain follows the user's mid-session
   `cd` and split-brains memory across subfolder hashes when
   `workspace.project_dir` is empty (the Pre.Audit symptom: a Green.World
   subfolder hash holding boot-context content that belonged in the
   parent's store). Mirrored in `statusline-command.sh` for invariant #2;
   `test_slug_anchored_to_transcript_path` pins all three sites.
5. **Runtime state is never packaged.** `.boot-context-*`, `.boot-marker-*`,
   `.replay-*`, `.skip-replay-*`, `search.db`, `statusline-token-rate.log`
   are derived/ephemeral (`.gitignore` + `install.sh` EXCL + the test scan
   must all agree).

## Portability

Engine root relocatable: `MEMORY_SEARCH_DB` > `$MEMORY_PACK_HOME` >
`~/.memory-pack` (honored by `index/*.py` + `memory-search-inject.sh`;
SCHEMA pointers resolve, not literal). `hooks/_lib.mjs`
`resolveSdkSpecifier` resolves the agent SDK portably (env > MPH-local >
unix globals > Windows `%APPDATA%\npm` > bare; degrades gracefully).
Install on any host: `git clone … && ./install.sh` (idempotent,
null-command-safe settings.json merge; `--uninstall`/`--check`;
`--with-sdk`). It also symlinks `~/.claude/statusline-command.sh`→
`$PREFIX/statusline-command.sh` and merges `.statusLine` via
`merge-settings.sh --statusline` (opt-in arg; ownership keyed on basename
`statusline-command.sh` exactly like hooks; foreign statuslines + sibling
keys e.g. `padding` untouched; a pre-existing real file is never clobbered;
`--uninstall` removes the owned symlink + `.statusLine`). Covered by
`test_install` + `test_settings_merge`. **Windows = WSL2** (engine runs unchanged). A native
PowerShell port was analyzed and **deliberately declined** (permanent
dual-maintenance, negative-EV, reinvites silent amnesia). Native-only
boundary documented at `tests/test_path_portability.mjs:1` — do NOT "fix"
the POSIX-correct `/memory/archive/` string ops, `python3`-vs-`python`,
or slug encoding for native without revisiting that decision.

## Tests

22 suites in `tests/` — run all before any commit (CI mirrors the same
loops on ubuntu + macos: `.github/workflows/test.yml`):

```
for t in tests/test_*.sh;  do bash "$t"  || echo "FAIL $t"; done
for t in tests/test_*.mjs; do node "$t"  || echo "FAIL $t"; done
```

`test_hash_shim` (value-preservation + python3 + loud-fail + statusline
parity), `test_mph_resolution` (MEMORY_PACK_HOME + no-hardcoded-path,
runtime-state-excluded), `test_hooks_wired`, `test_install`,
`test_settings_merge`, `test_sdk_resolve`, `test_path_portability`,
`test_recall_frontmatter_preserve` (recall hook must NOT reshape
frontmatter — runs the real `update-recall.mjs` + real Python
`parse_frontmatter` against flat/nested/`node_type` fixtures; guards the
silent-amnesia class), `test_inject_preamble_epistemic` (the
memory-hint inject preamble must carry the verify-before-asserting
epistemic clause, not just the relevance gate — structural-source pin
for the *read-side* analog of the silent-amnesia class),
`test_pending_header_epistemic` (the PENDING_MEMORIES.md header template
in `replay.mjs` must label proposals unverified-claims, name
confabulation, and carry a ground-truth verification step — transcripts +
live systems — that PRECEDES the Create/Merge choice; review-side sibling
of the inject-preamble pin, born of the 2026-06-11 incident where a
detached replay narrated a carried-forward TODO as observed fact — see
`feedback_verify_replay_memory_proposals` in the Rikkei-HelpDesk store),
`test_statusline_marker_path` (statusline must read
`.boot-marker-<id>`/`.skip-replay-<hash>` from the same dir the writers
write them — self-located via the symlink, BSD-safe bare `readlink`, no
hardcoded Resilio path; structural + behavioral-via-symlink + a
pending/booted contents mutation; the reader↔writer path-parity analog of
invariant #2, silent on relocated installs),
`test_slug_anchored_to_transcript_path` (PROJECT_HASH must derive from
CC's per-session slug = `basename(dirname(transcript_path))` walked back
up from cwd, not from the live cwd that follows mid-session `cd` — pins
the resolver in `_lib.sh`, its use in `boot-inject.sh` +
`session-end.sh` + `statusline-command.sh`, a behavioral subprocess that
loads a parent-hash boot-context when cwd is a subfolder, and a value
mutation where parent context wins over a sibling subfolder context;
guards the writer↔CC path-parity analog of invariant #4, the
silent-amnesia mode that split Pre.Audit's boot-contexts across
Green.World/ACPay/Red.Sunrise subfolder hashes),
`test_nerdfont_helper` (`_mp_have_nerdfont` env override + fc-list probe;
must produce NO stdout on every branch — silent-amnesia analog because
the helper is sourced by `statusline-icons.sh`),
`test_log_token_rate` (Stop hook `log-token-rate.sh`: happy/race-lost/
empty/missing/snake↔camel paths + malformed-JSONL doesn't crash;
backfill semantics — emits one cum per turn boundary (assistant whose
next user-or-asst is a real user-prompt — NOT tool_result continuation,
NOT `isMeta:true` mid-turn system-reminder; isMeta skip is load-bearing
per real-CC transcripts, mutation-pinned), idempotent re-fire, monotonic
cum>last_cum filter, per-session isolation; cumulative tokens are sum of
all 4 fields so a dropped subfield kills 4 assertions),
`test_statusline_render` (the renderer cluster: theme + icons + render
helpers + statusline-command.sh integration. ~129 assertions covering
source-time silence on every sourced helper, ICON_* existence in both
Nerd/Unicode tables, `mp_pill_fg` luminance flip with mid-boundary
coverage, `mp_gradient_color` interpolation across all 4 segments,
`mp_sparkline_data` 16-cap + negative-clamp, full/medium/narrow render
output line counts + bar widths + sparkline glyph presence + boot
indicator preservation across all width modes, COLUMNS=0/empty/unset
coerce-to-default — pins the silent-amnesia analog where CC spawns the
statusline subprocess with `COLUMNS=0` and `${COLUMNS:-80}` keeps it at
`0` because `:-` only substitutes for unset/empty, so line 3 silently
dropped on every CC invocation; plus the cache-age-clock REMOVAL contract
— no clock token, no `.statusline-clock-*` anchor side effect, no
`mp_clock_format` — and a ≤3-jq-forks pin on the single-pass stdin
extraction),
`test_bilingual_stdin` (invariant #3 across EVERY stdin-parsing hook:
structural scan that any JSON-accessor read of a snake_case CC field
carries its camel twin on the same line, plus behavioral camel-only
stdin through auto-save-stop — trigger fires — and memory-recall —
recall_count bumps AND per-session dedup holds; the dedup loss was the
nasty one: empty session_id inflated counts → wrong auto-promotions),
`test_real_user_turns` (`_mp_real_user_turns` + `_mp_conversation_chars`
units + session-end trivial-skip/carry-forward behavioral with node
stubbed via PATH + the auto-save tool-heavy no-trigger case; pins that
turn counters count REAL prompts, not tool_result/isMeta entries — a real
594-line transcript held 153 user-type entries but 2 prompts — AND the
substance rescue: few-turn sessions big on either axis (conversation
chars / raw bytes) must replay, 0-turn headless must not, `MP_REPLAY_MIN_*`
knobs mutation-pinned in both directions; the chars helper mirrors
`extractConversation` incl. first-assistant-block-only),
`test_replay_extraction` (`extractConversation`: isMeta string/array
exclusion, tool_result exclusion, array-text prompt inclusion;
`truncateConversation`: head/tail preservation + elision marker + default
caps; structural pin that replay.mjs consumes both),
`test_session_end_launcher` (quote-safe env-passing launcher: apostrophe
project path still replays; failure path writes per-project
`.replay-error-<hash>.log` + synthetic banner + exit marker; no fixed
/tmp log; unique tmp.$$; skip-replay sentinel consumed one-shot with NO
launch and carry-forward of the prior boot context),
`test_memory_search_inject` (the FTS5 pipeline end-to-end: real indexer
over a sandboxed store — build / nested-shape type resolution / archived
status / incremental edit+delete sync — then the real inject hook via
MEMORY_SEARCH_DB: relevant prompt injects with the epistemic preamble,
nonsense/slash/short prompts and an impossible threshold inject NOTHING.
Fixture corpus is padded to 15 docs because BM25 IDF collapses to ~0 in a
tiny corpus and the production -8.0 threshold can never be cleared),
`test_runtime_state_gc` (auto-save prunes 7d-old `*_last_save` + rotates
hook.log >512KB→500 lines; log-token-rate rotates >4000→2000 lines with
newest samples surviving; boot-inject SessionStart sweeps legacy
`.statusline-clock-*`; every sweep has a keep-fresh mutation guard),
`test_archive_resurrect_preserve` (resurrect must not reshape: nested
`metadata:` children/`node_type` survive byte-for-byte while
created/recall_count inherit and last_reviewed stamps; malformed files
untouched; pins the shared `fmParse`/`fmSetInPlace`/`fmSerialize` in
`_lib.mjs` consumed by BOTH update-recall.mjs and archive-resurrect.mjs).
Two accepted patterns for the side-effecting
`.mjs`/`.sh` scripts (they can't be unit-imported): **structural
source-regression** (`test_sdk_resolve.mjs:62` idiom) — scan code-only
(exclude comment lines AND runtime-state dotfiles), assert the portable
form present / POSIX-only form absent; or **behavioral subprocess**
(`test_install.sh` / `test_recall_frontmatter_preserve.mjs` idiom) — run
the real script against temp fixtures and assert observable output. For
value-critical assertions add a mutation check (corrupt → watch the test
fail on value → revert).

## Gotchas

- The `Bash` tool runs under **zsh**: unquoted `$var` does NOT word-split
  (bash-ism). Use explicit literal lists or arrays in loops.
- Editing a memory file you just `Read` races `update-recall.mjs`
  (frontmatter bump). Edit memory files via Bash+Python fresh-read +
  atomic `os.replace`, never the Edit tool — see
  `feedback_memory_edit_recall_race.md` in the project memory store.
- BSD (macOS) vs GNU sed/`md5sum` differ; macOS ships `md5`, Linux
  `md5sum`. Prefer `awk`/`python3` over sed quantifier tricks.
- `os.replace`/`mv` do NOT fire the PostToolUse indexer hook — run
  `index/index-memories.py` (incremental) after out-of-band file moves,
  or let SessionEnd `memory-index-reconcile.sh` catch it.
