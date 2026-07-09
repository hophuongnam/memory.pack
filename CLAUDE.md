# Memory.Pack — engine dev/maintenance guide

Session-continuity + auto-memory engine for Claude Code. Git repo
(`github.com/hophuongnam/memory.pack`, branch `main`), wired globally from
`~/.claude/settings.json` — hooks run by **absolute path**, never symlinked
per-project. `hooks/` is the single source of truth. Two kinds of artifact
are symlinked into `~/.claude` so the repo OWNS them (version-controlled):
`statusline-command.sh` (repo root) → `~/.claude/statusline-command.sh`
(invoked via settings.json `statusLine.command`), and each `skills/<name>/`
→ `~/.claude/skills/<name>` — the `memory-search` + `memory-lint` skills CC
discovers (symlink-following + `$MEMORY_PACK_HOME`-portable bodies verified
CC 2.1.177; see `reference_cc_skill_symlink_discovery` in the project store).
This project owns its development (relocated out of the Management project
2026-05-18); `install.sh` wires both symlinks + `.statusLine` on any host,
foreign-safe (a pre-existing real file/dir of the same name is never
clobbered; `--uninstall` removes only symlinks pointing into `$PREFIX`).

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

**14 hook registrations** (canonical list: `install/hooks.manifest.json`):
`SessionStart`→boot-inject; `UserPromptSubmit`→boot-inject + memory-search-inject;
`SessionEnd`→session-end + memory-index-reconcile; `Stop`→auto-save-stop +
log-token-rate + fetch-usage; `PostToolUse` (matcher-less, all tools)→boot-catchup,
Read→memory-recall, Write→archive-resurrect + memory-index-update,
Edit/MultiEdit→memory-index-update. Boot context is thus injected at THREE
sites — SessionStart (polls 4s), UserPromptSubmit (polls 9s), and
`boot-catchup.sh` on PostToolUse (mid-turn catch-up): when the prior
session's detached replay outlasts both poll windows the `.boot-context-<hash>`
lands mid-turn and only the next prompt would inject it — too late for a long
turn in flight. boot-catchup fast-rejects forklessly (`${0%/*}` + glob) when
the shared `hooks/` dir holds NO live context; otherwise — that dir is shared
across ALL projects, each writing its own `.boot-context-<hash>` — it reads
stdin and resolves THIS session's hash (`_mp_resolve_project_key`, exactly
like boot-inject, invariant #4) and `exec`s boot-inject.sh ONLY for our own
`.boot-context-<hash>`. Handing a foreign project's unconsumed leftover to
boot-inject would make it emit "[No boot context available]" + flip our marker
to `none` on every tool call (the shared-dir contamination class — pinned by
`test_boot_catchup`). boot-inject already handles `EVENT=PostToolUse` and emits
the context as `additionalContext` (CC injects a PostToolUse hook's
additionalContext into the model on its next request within the SAME turn —
verified in bundle 2.1.181, see
`reference_cc_posttooluse_additionalcontext` in the project store).

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
`SAVE_INTERVAL=10` REAL user turns (`_mp_real_user_turns` in `_lib.sh`:
tool_results, isMeta bookkeeping, and slash-command entries excluded — raw
`"type":"user"` counting fired after ~50 transcript ENTRIES ≈ a handful of
real turns; same counter feeds session-end's trivial-replay skip, which
skips only when turns ≤5 AND the session is small on BOTH substance axes:
`_mp_conversation_chars` < `MP_REPLAY_MIN_CHARS` (25k) AND raw transcript
< `MP_REPLAY_MIN_BYTES` (200KB) — a 2-prompt session can be a 2MB
autonomous monster worth replaying, and tool-heavy monsters hold few
conversation chars so BOTH axes are load-bearing; 0-turn headless
sessions always skip). Tool-heavy sessions accrue REAL turns too slowly
to ever reach 10 (a measured 2026-06-13 session: 2MB / 2 turns), so (a)
ALSO trips when RELEVANT OUTPUT grows ≥ `MP_AUTOSAVE_MIN_CHARS` (100k,
env-tunable) since the last size-save. Relevant output
(`_mp_relevant_output_chars`) = conversation + exec results
(Bash/remote_run/remote_script) + edit inputs (Edit/Write/MultiEdit/
NotebookEdit); NOT raw `wc -c`, which OVER-fired — on context-heavy
sessions file-reads + attachments dominate the transcript (a 2.6MB
NexusLit session fired on prompt 1 at only ~180k relevant), so the raw
axis checkpointed on context volume, not work. Narrowing fixes the
over-fire; the LIVE checkpoint still feeds Claude its FULL context, so
this is fire-RATE, not what the detached replay (extractConversation)
saves. The two axes keep INDEPENDENT baselines in `${sid}_last_save`
(`"<turns> <relevant>"`, legacy `<bytes>` 2nd field tolerated — read as
relevant, a stale large value just makes the delta negative until
re-baselined) so a size-save never resets the statusline turn-countdown
(which tracks the turn axis alone — a size-save can fire sooner)
→ Claude writes bodies. (b) `boot-inject.sh`
writes `sessions.log.md`/`SESSIONS.md`. (c) `replay.mjs` pass 2 writes
`PENDING_MEMORIES.md`. (d) `memory-recall.sh`→`update-recall.mjs` edits
*frontmatter only* (recall_count/last_recalled), session-deduped, and
auto-promotes archived→active at `recall_count>=3`. The CC harness
auto-stamps `originSessionId` on every memory Write/Edit — legitimate,
never strip it.

**Per-model usage segment** (`fetch-usage.sh` → `fetch-usage-worker.sh`):
CC's statusline stdin carries only the COMBINED `five_hour`/`seven_day`
windows — never a per-model breakdown. The per-model weekly windows (e.g.
Fable) exist only in Anthropic's OAuth usage endpoint
(`api.anthropic.com/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20`),
in a newer `limits[]` array whose per-model entries are exactly those with a
`scope.model.display_name` — filter on that PRESENCE, never on
`kind=="weekly_scoped"` and never on the literal `"Fable"`, or a model
rename silently empties the segment. The launcher TTL-gates (120s) and
`nohup`-detaches; the worker reads the ACTIVE account's token (macOS
Keychain `Claude Code-credentials`, else plaintext `.credentials.json`),
curls, and atomically replaces `hook_state/usage_scoped`:
`<fetch_epoch>\n<pct> <resets_epoch> <display name>` (name LAST so a plain
`read` slurps spaces; the stamp line is load-bearing — it is what the TTL
gate compares against, and it lands even for an account with ZERO scoped
windows, which would otherwise re-fetch every turn). The token rides a curl
CONFIG FILE on stdin (`curl --config -`), NEVER argv — `-H "…Bearer $tok"`
publishes a live OAuth token to `ps aux`. **No token refresh, ever**: we
only read the token CC itself owns and keeps fresh, so an expired token just
skips the tick (no `invalid_grant` quarantine, no 401-retry, no persist
callback — ~150 lines of claude-swap we never write). Any failure (no token,
network, changed shape) leaves the last-good cache UNTOUCHED and exits 2;
statusline renders it stale and drops the segment past 24h rather than lie.
Undocumented endpoint: when `limits[]` changes shape the segment vanishes
quietly — the tests pin OUR parser, not their schema.

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

Engine root relocatable: `index/*.py` resolve the DB via
`$MEMORY_PACK_HOME` > `~/.memory-pack` and deliberately IGNORE
`MEMORY_SEARCH_DB` (pinned by `test_mph_resolution`); only
`memory-search-inject.sh` honors `MEMORY_SEARCH_DB` as a highest-precedence
override (SCHEMA pointers resolve, not literal). `hooks/_lib.mjs`
`resolveSdkSpecifier` resolves the agent SDK portably (env > MPH-local >
unix globals > Windows `%APPDATA%\npm` > bare; degrades gracefully).
Install on any host: `git clone … && ./install.sh` (idempotent,
null-command-safe settings.json merge; `--uninstall`/`--check`;
`--with-sdk`). It also symlinks `~/.claude/statusline-command.sh`→
`$PREFIX/statusline-command.sh` and merges `.statusLine` via
`merge-settings.sh --statusline` (opt-in arg; ownership keyed on basename
`statusline-command.sh` exactly like hooks; foreign statuslines + sibling
keys e.g. `padding` untouched; a pre-existing real file is never clobbered;
`--uninstall` removes the owned symlink + `.statusLine`). Likewise each
`$PREFIX/skills/<name>` → `~/.claude/skills/<name>` (foreign-safe, same
ownership rule; real dir of the same name skipped + warned) — skills are
auto-discovered, so they have NO settings.json entry (covered by
`test_install` only; the statusline path is covered by `test_install` +
`test_settings_merge`). **Windows = WSL2** (engine runs unchanged). A native
PowerShell port was analyzed and **deliberately declined** (permanent
dual-maintenance, negative-EV, reinvites silent amnesia). Native-only
boundary documented at `tests/test_path_portability.mjs:1` — do NOT "fix"
the POSIX-correct `/memory/archive/` string ops, `python3`-vs-`python`,
or slug encoding for native without revisiting that decision.

## Tests

25 suites in `tests/` — run all before any commit (CI mirrors the same
loops on ubuntu + macos: `.github/workflows/test.yml`). Use this
fail-propagating form — a bare `|| echo FAIL` loop exits 0 even when
suites fail:

```
fail=0
for t in tests/test_*.sh;  do if bash "$t" >/dev/null; then :; else echo "FAIL $t"; fail=1; fi; done
for t in tests/test_*.mjs; do if node "$t" >/dev/null; then :; else echo "FAIL $t"; fail=1; fi; done
exit $fail
```

`test_hash_shim` (value-preservation + python3 + loud-fail + statusline
parity), `test_mph_resolution` (MEMORY_PACK_HOME + no-hardcoded-path,
runtime-state-excluded), `test_hooks_wired`, `test_install`,
`test_settings_merge`, `test_sdk_resolve`, `test_path_portability`,
`test_update_recall_promotion` (the archive→active auto-promotion path:
flat promote + MEMORY.md section insert + marker move + audit log,
collision-skip, NaN-threshold fallback, nested archive/sub/ promotes to
the memory ROOT by basename, below-threshold mutation guard, and the
size-capped `.archive-promote.log` rotation),
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
`test_statusline_render`'s scoped-segment cluster (per-model windows on line
2: bar + ↻ in full, percentage-only in medium/narrow via `format_pct`'s
`compact` arg — medium already spends ~66 of 80 columns on ctx/5h/7d, and
dropping the segment instead would hide a MAXED window on a split pane; the
24h hard-drop boundary; the epoch-0 sentinel hiding ↻ rather than printing
"now"; torn rows SKIPPED silently — asserted by grepping the ICON, since a
row torn to just "2" has no name to grep and a missing empty-name guard
renders a nameless pill; and a torn STAMP under real dash, the one FATAL
arithmetic surface, which must still render all 3 lines),
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
extraction; plus the line-1 turns-until-autosave countdown —
`<remaining>↓` read from `hook_state/<sid>_turns` via a plain shell `read`
(NO jq, so the fork budget holds), OK/WARN/CRIT color ladder mutation-pinned
at the 30%/10%-of-interval boundaries, since>interval clamped to `0↓`,
absent file → hidden, and a corrupt/torn file (a float or bare identifier)
must NOT blank the whole render — a FATAL arithmetic error under dash
(Linux /bin/sh), suite-run under real `/bin/dash` where present (macOS and
CI ubuntu both ship it), as are the garbage rate-limit-epoch renders),
`test_bilingual_stdin` (invariant #3 across EVERY stdin-parsing hook:
structural scan that any JSON-accessor read of a snake_case CC field
carries its camel twin on the same line, plus behavioral camel-only
stdin through auto-save-stop — trigger fires — and memory-recall —
recall_count bumps AND per-session dedup holds; the dedup loss was the
nasty one: empty session_id inflated counts → wrong auto-promotions),
`test_real_user_turns` (`_mp_real_user_turns` + `_mp_conversation_chars` +
`_mp_relevant_output_chars` units + session-end trivial-skip/carry-forward
behavioral with node stubbed via PATH + the auto-save SMALL-tool-heavy
no-trigger AND relevant-output size-axis trigger cases; pins that
turn counters count REAL prompts, not tool_result/isMeta entries — a real
594-line transcript held 153 user-type entries but 2 prompts — AND the
substance rescue: few-turn sessions big on either axis (conversation
chars / raw bytes) must replay, 0-turn headless must not, `MP_REPLAY_MIN_*`
knobs mutation-pinned in both directions; the chars helper mirrors
`extractConversation` incl. first-assistant-block-only; plus auto-save-stop
caching `<since_last> <interval>` to `${sid}_turns` every Stop for the
statusline countdown — value-pinned, skipped on 0-turn Stops; plus the
RELEVANT-OUTPUT size axis (`_mp_relevant_output_chars` = conv +
Bash/remote results + Edit/Write inputs): a big-raw file-READ session does
NOT trip (raw bytes over-fire on context volume) while Bash-heavy AND
Edit-heavy 2-turn sessions DO — the edit-input term is mutation-pinned
(emptying the edit-tool set drops edit-heavy work and re-opens the amnesia
gap) — `MP_AUTOSAVE_MIN_CHARS` (default 100k) knob pinned both directions,
and a relevant-trip leaves the TURN baseline untouched so the countdown
stays honest — independent `"<turns> <relevant>"` baselines in
`${sid}_last_save`),
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
`test_runtime_state_gc` (auto-save prunes 7d-old `*_last_save` + `*_turns` + rotates
hook.log >512KB→500 lines; log-token-rate rotates >4000→2000 lines with
newest samples surviving; boot-inject SessionStart sweeps legacy
`.statusline-clock-*`; every sweep has a keep-fresh mutation guard),
`test_archive_resurrect_preserve` (resurrect must not reshape: nested
`metadata:` children/`node_type` survive byte-for-byte while
created/recall_count inherit and last_reviewed stamps; malformed files
untouched; pins the shared `fmParse`/`fmSetInPlace`/`fmSerialize` in
`_lib.mjs` consumed by BOTH update-recall.mjs and archive-resurrect.mjs),
`test_fetch_usage` (the per-model usage refresh: `security` AND `curl` both
shadowed by PATH stubs that RECORD their invocation, so a hook reaching the
real binary by absolute path fails the suite loudly instead of silently
hitting api.anthropic.com with a live OAuth token. Layer 1 stubs the worker
and drives the launcher's TTL gate — fresh cache must NOT spawn, stale and
corrupt-stamp must, and a corrupt stamp must not reach `$(( ))` (run under
real dash: fatal there, merely noisy under bash). Layer 2 drives the REAL
worker synchronously — happy path, token ABSENT from curl argv but present
in the stdin config, curl failure / malformed JSON / missing `limits[]` all
leave the last-good cache byte-identical, zero-scoped-window accounts get a
stamp-only cache, a display name with spaces survives `read` because name is
the LAST field, missing `resets_at` → epoch-0 sentinel, no tmp litter, token
never persisted. Mutation-pinned in four directions: TTL gate, dash
int-guard, token-into-argv, clobber-on-parse-failure),
`test_boot_catchup` (the PostToolUse mid-turn catch-up: a forkless gate
that `exec`s boot-inject only for a LIVE `.boot-context-<hash>`, never the
`.boot-context-last-<hash>` carry-forward snapshot — Layer 1 stubs
boot-inject to isolate the gate, with a mutation that strips the `-last-`
exclusion and watches the stale snapshot leak through; Layer 2 runs the
REAL boot-inject with an `EVENT=PostToolUse` stdin and asserts it emits
`hookEventName:"PostToolUse"` additionalContext + mv's the live file to the
carry-forward snapshot + injects nothing on the next tool call once the gate
is dry; guards the mid-turn analog of the boot-context injection path — a
slow prior-session replay landing after both poll windows must not leave a
long turn blind).
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
