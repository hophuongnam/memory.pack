---
name: memory-lint
description: Audit the auto-memory store for drift — stale project memories, broken file/host references, orphan files, index mismatches, duplicates. Reports a punch list and waits for confirmation before fixing. `--archive [N]` proposes leaf memories to move into archive/ to shrink an over-cap MEMORY.md. Use when the user types /memory-lint or asks to "check", "audit", "clean up", "verify", "archive", or "trim" memory.
---

# Memory Lint

Audit the per-project auto-memory store for drift and report a fix punch list. **Never auto-fix** — report first, let the user approve changes.

## Locations

**Memory dir** (per-project, derived from cwd):
```
~/.claude/projects/<slugified-cwd>/memory/
```
Slugify the absolute cwd by replacing BOTH `/` and `.` with `-` (the leading `/` yields the `-` prefix). Example: cwd `/Users/namhp/Resilio.Sync/Management` → `-Users-namhp-Resilio-Sync-Management` (note the dot in `Resilio.Sync` became `-`).

**Canonical schema** (shared across all projects, single source of truth):
```
$MEMORY_PACK_HOME/SCHEMA.md
```
Read this **first** — it defines the frontmatter contract, type semantics, cross-reference rules, and `MEMORY.md` section layout that the lint checks are verifying against. If the schema has been edited since you last ran, let the edits drive the audit (e.g. if a new optional field was added, stop flagging it as drift).

There is **no per-project `SCHEMA.md`**. If you find one inside a project memory dir, flag it as an orphan to be removed — it's a legacy copy that predates the canonical location.

## What to check

Walk every `.md` file in the memory dir. For each, evaluate the checks below. Collect findings into a single report — do not fix anything yet.

### 1. Index ↔ file consistency
- Every `.md` file in the dir (except `MEMORY.md`, `sessions.log.md`, `SESSIONS.md`, and `PENDING_MEMORIES.md`) must have exactly one pointer line in `MEMORY.md`. Flag **orphan files** (on disk, not in index) and **dead index entries** (pointer to a missing file).
- The orphan check is for memory files only. **Skip all non-`.md` files and all dotfiles.** In particular, `.recalled-<session>-<memory>.touched` sidecar markers written by `Memory.Pack/hooks/update-recall.mjs` for session-level recall dedup are NOT orphans — never flag, never remove them here. They self-purge after 2 days via the recall updater's opportunistic cleanup.
- `.archive-resurrect.log` is the audit trail written by `Memory.Pack/hooks/archive-resurrect.sh` when a Write to `<memory-dir>/<basename>.md` collides with an archived `<memory-dir>/archive/<basename>.md` and the archived metadata gets auto-inherited (see SCHEMA.md "Auto-resurrect on slug collision"). Also a dotfile — skip in every check, never flag.
- `sessions.log.md` is an append-only archive of prior-session replay outputs written by `Memory.Pack/hooks/boot-inject.sh`. It is **not a memory file**: skip it in every check (index, frontmatter, references, duplicates). Do not flag, do not rewrite, do not index it in `MEMORY.md`.
- `SESSIONS.md` is a one-line-per-session timeline maintained by `Memory.Pack/hooks/boot-inject.sh` alongside `sessions.log.md`; it is read by `replay.mjs` to feed cross-session continuity into the next boot-context and promotion passes. Also **not a memory file**: skip it in every check.
- `PENDING_MEMORIES.md` is a review queue of memory proposals emitted by the replay agent's promotion pass (`Memory.Pack/hooks/replay.mjs`), awaiting human-in-the-loop review. Also **not a memory file**: skip it in every check. If you find it during a lint run, note it once under **SUGGEST** as "pending proposals to review per file's own protocol" — do not act on the proposals yourself during a lint run; the lint audit and the pending-review flow are separate.
- A project-local `SCHEMA.md` is a legacy artifact — flag it as an orphan to be deleted; the canonical schema is at `$MEMORY_PACK_HOME/SCHEMA.md`.
- The index line's description should still match the file's frontmatter `description:`. Flag drift.
- If `MEMORY.md` is ungrouped (flat list, no `##` section headers), flag as SUGGEST with the grouping from the canonical schema.

### 2. Frontmatter validity
- Each memory file must have `name`, `description`, and `type` in frontmatter.
- `type` must be one of: `user`, `feedback`, `project`, `reference`.
- `originSessionId`, `node_type` and `modified` are legitimate metadata auto-injected by the Claude Code harness (confirmed in the compiled binary; `node_type: memory` lands in only a subset of files, intermittently, per CC write path/version. `modified` is an ISO-8601-with-ms write timestamp that arrived with a mid-July-2026 CC build — earliest value corpus-wide is 2026-07-18 — so older untouched memories simply lack it; censused 2026-07-29 at 134 files across 9 stores, 124 nested / 16 flat). **Never flag any of them as drift. Never remove them** — the harness re-adds them on the next edit, so removal is a no-op that churns the file. Frontmatter may also be nested under a `metadata:` wrapper (the stock system prompt's shape): that is tolerated, not drift — recognized keys are matched at any indentation, and `Memory.Pack/hooks/update-recall.mjs` preserves whatever shape it finds (it never reshapes a file). **Never propose flattening a nested file**, not even as a SUGGEST: the write-side flat rule was retired 2026-07-10 (SCHEMA.md history note), 42% of the corpus is nested, and the harness re-nests on the next `Write` anyway. When counting or matching frontmatter keys yourself, anchor tolerantly — `grep -E '^[[:space:]]*type:'` — never a bare column-0 anchor, which silently misses every nested memory.
- Decay-tracking fields are legitimate optional metadata: `created`, `last_recalled`, `recall_count`, `last_reviewed`. Never flag as drift, even when missing. `last_recalled` and `recall_count` are auto-maintained by `Memory.Pack/hooks/memory-recall.sh`; `last_reviewed` is set by this skill's `--decay` flow.
- Flag missing or malformed `name`/`description`/`type`. Flag any field other than the ten recognized ones (`name`, `description`, `type`, `originSessionId`, `node_type`, `modified`, `created`, `last_recalled`, `recall_count`, `last_reviewed`).

### 3. Reference rot (the important one)
For each memory, extract every concrete reference it makes and verify it *still exists now*:

- **File paths / directories**: check with `ls` or Read. If a memory says "the hook lives at `~/.claude/hooks/boot-inject.sh`" and the file is gone, flag it.
- **Hosts / IPs**: if the memory names Tailscale hosts or IPs, cross-check against current `tailscale status` output (only if `tailscale` is on PATH and the user is logged in — otherwise note "unverified").
- **URLs / domains**: do not fetch — just list them so the user can eyeball.
- **Services / containers / ports**: if the memory names a docker container or systemd service, verify with `docker ps` or `systemctl list-units` only when the memory explicitly claims the service is on the *local* machine. For remote hosts, mark "unverified (remote)".
- **Commands / binaries**: `command -v` to check presence.

Do not verify references inside `user` or `feedback` memories — those are about preferences, not state.

### 4. Temporal staleness (project memories only)
Project memories often pin to a date or deadline. Parse for:
- Explicit dates in the body (`YYYY-MM-DD` or `2026-03-05`-style). If the date has passed and the memory describes a *future* event ("freeze begins", "launches on", "deadline"), flag as **expired**.
- Relative markers that were converted to absolute dates at save time. If >90 days old and describes in-progress work, flag as **likely stale — verify still active**.
- A `**Why:**` line whose reason no longer applies (e.g. "because of the Q1 launch" and Q1 is over). This requires judgment — flag, don't assert.

Today's date is available in the system prompt's `currentDate` block. Use it as ground truth.

### 5. Duplicate / overlap
- Compare memories pairwise by topic. Flag pairs with >50% topical overlap for possible merge.
- Flag memories that restate the same fact stored elsewhere (e.g. a project memory that inlines a tailscale IP already stored in `reference_tailscale_hosts.md`).

### 6. Missing cross-references
- If memory A mentions an entity (host, project, service) that has its own memory file B, and A does not link to B with a relative markdown link, flag as **missing xref: A → B**.

### 7. Index hygiene
- `MEMORY.md` should stay under the 150-line soft cap (harness hard-truncates at 200 lines or 25KB per [official docs](https://code.claude.com/docs/en/memory)). Flag if approaching 150.
- When the index is near or over 150 lines, report it under a dedicated **INDEX CAP** section and propose the two remedies in order: **first trim over-length index lines** (zero memory loss), **then archive** with the `--archive` selector below. Do NOT rank eviction candidates by strength or by `recall_count` — see `--archive` for why both invert relevance.
- Each index line should be under ~150 chars. Flag overlong entries.

## How to run the audit

1. **Read the index** (`MEMORY.md`) and list all files in the memory dir. Build a set of indexed files and a set of on-disk files.
2. **Read every memory file** in parallel (batch the Read calls in one message).
3. **Extract references** from each body. A reference is any concrete claim that can be falsified: a path, host, IP, URL, date, service name, container name, port, command.
4. **Verify** in parallel: batch `ls` / `command -v` / `tailscale status` / `docker ps` calls when applicable. Cap remote/expensive checks — prefer local verification.
5. **Assemble the report** as a punch list grouped by severity:
   - **BROKEN** — reference confirmed dead (file gone, host unreachable, service removed)
   - **EXPIRED** — date-pinned memory whose date has passed
   - **DRIFT** — index/frontmatter mismatch, overlong lines
   - **INDEX CAP** — `MEMORY.md` at/near 150 lines (only when triggered — not on every run); point the user at line-trimming, then at `--archive`
   - **SUGGEST** — duplicates, missing xrefs, likely-stale project memories
   - **DECAYED** is produced only in `--decay` mode; **ARCHIVE CANDIDATES** only in `--archive` mode (see both sections below).

## Reporting format

Output the report as markdown, grouped by severity, with one line per finding. Each finding must cite the file and the offending content. Example:

```
## BROKEN (2)
- `project_foo.md` — references `/Users/namhp/tools/old-cli` which no longer exists
- `reference_bar.md` — lists host `jumpbox-2` (100.64.0.12) not in current `tailscale status`

## EXPIRED (1)
- `project_merge_freeze.md` — "freeze begins 2026-03-05"; today is 2026-04-11

## DRIFT (1)
- `reference_toolkit_server.md` — frontmatter description "Toolkit VPS" but MEMORY.md says "Toolkit server (vmi3112658, …)"

## SUGGEST (2)
- `project_securevectors_migration.md` ↔ `reference_toolkit_server.md` — add xref (securevectors prototype runs on toolkit)
- `reference_tailscale_api_key.md` — verify the key still works (last confirmed 2026-04-09)
```

End the report with a single question: **"Want me to fix these? I'll go item by item."** Then wait.

## Fix phase (only after user confirms)

When the user says yes:
- Walk the punch list in order. For each item, state what you're about to do and do it with Edit (for body/index edits) or prompt the user before deleting any file.
- **Never delete a memory file without explicit per-file confirmation.** "Remove the broken one" is not enough — name the file.
- After each batch of fixes, re-run the relevant check (don't re-run the whole lint).
- Update `MEMORY.md` last, so the index always reflects the final file set.

## What NOT to do

- Do not fetch URLs during lint. List them for the user to check manually.
- Do not SSH to remote hosts to verify services. Mark remote claims as "unverified (remote)".
- Do not rewrite memories to be "cleaner" — only fix what's actually broken or flagged.
- Do not edit the canonical `$MEMORY_PACK_HOME/SCHEMA.md` during a lint run — it is the user-editable contract that the audit is checking *against*, not a target of the audit. Read it to inform findings; never rewrite it. (A project-local `SCHEMA.md`, however, is a legacy orphan and should be flagged for removal.)
- Do not add findings for things that are merely *old*. Age alone is not staleness; expired-future-events and dead-references are.

## Archive mode (`/memory-lint --archive [N]`)

Separate, opt-in mode. Moves leaf memories into `<memory-dir>/archive/` to shrink an over-cap `MEMORY.md`. Nothing is deleted — the archive is a recurrence detector, and `Memory.Pack/hooks/update-recall.mjs` promotes a file back to active after `MEMORY_PROMOTION_THRESHOLD` post-archive reads.

**`N` is a ceiling, not a quota.** Ship fewer than `N` when the selector yields fewer, and say so. The moment the count drives the set instead of the selector, the run is unsafe.

### Try trimming first

Archiving is the second remedy. If the trigger is the byte cap ("entries too long"), **trim index lines over ~150 chars first** — zero memory loss, and it has repeatedly recovered enough bytes on its own. Key each trim on the line's **first** `](slug.md)` link, never on any matching substring: long rollup entries embed inline cross-reference links, so substring matching edits the wrong line.

### Default selection: inbound cross-references

Rank by **inbound cross-reference count**, ascending. For each candidate slug:

```bash
grep -l "](<slug>.md)" *.md    # exclude the file itself, MEMORY.md, and the session files
```

Archive only **leaf nodes — inbound ≤ 1**.

⚠ **Do not rank by `recall_count` or decay strength**, even when the user asks for "the least used N". Both invert relevance in a well-recalled store: the recall hook stamps the *referencing* file, not its link targets, so the most cross-referenced hub memories sit at `recall_count: 0`. One past run archived the 50 "least used" that way and left 69 inbound links from 34 surviving files pointing into the archived set. When the user asks for "least used", state this once, then apply the inbound-xref selector. If the user asks again after hearing it, that is a decision — use `--by-recall` below.

### `--by-recall`: the literal least-used ranking

`/memory-lint --archive N --by-recall` ranks strictly by `recall_count` ascending, then by `strength` ascending as the tie-break — the literal "least used N". The age floor and the hard-excludes below still apply. This is an explicit operator override, so honor it when asked; do not substitute the inbound-xref ranking.

Two things this mode must still do:

1. **Show the inbound count on every candidate line anyway.** The ranking ignores it, the report does not — a candidate at `recall_count: 0, inbound: 12` is a hub, and the user needs to see that before confirming.
2. **Say the risk once, in one sentence, then proceed.** For example: "8 of these 50 carry 3+ inbound links and will break cross-references." Do not re-argue after the user confirms.

Everything else is unchanged: report and wait, `mv` the confirmed files, then run the canonicalizer and its `--check` verify.

### Age floor

Inbound-xref has the same cold-start defect: a memory written two days ago cannot have inbound links yet. Exclude any candidate where `age <= 7d`, with `age = today - max(last_recalled, created)`.

### Hard excludes (regardless of inbound count)

- Every `reference_*` memory — the schema says preserve.
- The `/memory-lint` rule memories themselves, and any workflow meta-rule.
- Memories about the current epic, the current incident, or today.
- High-`recall_count` rows that are named precedents for a prior eviction decision.

### Gather data with Bash, not Read

Use `grep`/`awk`/`sed` to read frontmatter and bodies during selection. The `Read` tool fires `Memory.Pack/hooks/memory-recall.sh`, which stamps `last_recalled` and `recall_count` on every file you audit — that corrupts the very signal the audit measures.

### Report, then wait

Group candidates under an **ARCHIVE CANDIDATES** heading, weakest-first, one line each with slug, type, inbound count, age, and the reason it reads as a leaf:

```
## ARCHIVE CANDIDATES (33 of 50 requested)
- `project_epic20_dispatch.md` (project) — inbound 0, age 64d — shipped, superseded by epic 23
- `feedback_screens_dir_layout.md` (feedback) — inbound 1, age 91d — `screens/` removed in the 14Q teardown
```

End with: **"Want me to archive these? I'll go item by item."** Then wait. Never move a file before the user confirms.

### Fix phase (archive mode)

1. `mkdir -p <memory-dir>/archive`, then move each confirmed file with `mv` (a Bash-level move — the `Write` tool would trip `archive-resurrect.sh`).
2. Remove each moved file's line from `MEMORY.md`.
3. Canonicalize every cross-reference link in one pass:
   ```bash
   python3 $MEMORY_PACK_HOME/index/memory-links.py <memory-dir>
   ```
   The canonicalizer resolves each `](...slug.md)` by where `slug.md` actually lives and rewrites it — `](slug.md)` or `](archive/slug.md)` from an active file, `](slug.md)` or `](../slug.md)` from an archived one. It is idempotent and bidirectional, so it also repairs pre-existing rot and the `archive/archive/…` double-prefix that a one-way "add the prefix" patch creates. Ad-hoc one-way rewrites took three passes and kept reopening breaks — always use this script.
4. Verify: re-run with `--check`. It must exit 0. The same run reconciles `MEMORY.md` against the on-disk active set, which catches orphan files and dead index entries that a byte-count check misses. Doc placeholders (`X.md`, `slug.md`) are classified separately and never counted as rot.
5. Report the before/after line count and byte size of `MEMORY.md`.

The FTS5 index needs no action — `hooks/memory-index-reconcile.sh` reindexes moves at SessionEnd.

## Decay audit (`/memory-lint --decay`)

Separate, opt-in mode. Standard lint checks stale claims; `--decay` checks stale *confidence* using Ebbinghaus-inspired scoring from the canonical schema.

### Strength formula (mirror of `SCHEMA.md`)

```
effective_half = max(type_half, 90)  if recall_count >= 10
              = type_half             otherwise
strength       = exp( -Δt / (effective_half × (1 + ln(1 + recall_count))) )
```

- `Δt = today - max(last_recalled, last_reviewed, created)` in days. If none of those are set, fall back to the file's mtime.
- Half-lives: `user`/`feedback` = 180d, `reference` = 90d, `project` = 21d.
- `recall_count` defaults to `0` when absent.
- **Recall-count floor**: when `recall_count >= 10`, the effective half-life is floored at 90 days (the `reference` half-life). In practice this only lifts `project` memories — feedback/user already exceed 90d, reference already sits at it. Rationale lives in `SCHEMA.md`'s Decay model section.

### What to report

Group the output under a **DECAYED** severity and sort weakest-first. For each memory with `strength < 0.3`, show:

```
## DECAYED (N)
- `project_foo.md` (project) — strength 0.18, last_recalled 2026-02-14 (67d), recall_count 0
- `reference_bar.md` (reference) — strength 0.27, never recalled, age 142d
```

`<0.3` is a **surfacing threshold**, not an archive trigger. The historical `<0.1 AND 60d no recall` archive-candidate gate was removed — with the recall hook stamping `last_recalled` on every Read, it essentially never fired. **Archive proposals come from `--archive`**, never from a strength ranking — strength degenerates in an active store, because everything in use stays fresh. Per-item fix flow is the same in both modes.

End with: **"Want me to reinforce, edit, or archive these? I'll go item by item."**

### Fix phase (decay mode)

Per item, offer four actions:

- **reinforce** — set `last_reviewed: <today>` in frontmatter (resets decay clock without bumping `recall_count`; review ≠ recall).
- **edit** — open the file for content updates; afterwards reinforce.
- **archive** — move the file to `<memory-dir>/archive/`, remove its line from `MEMORY.md`. Create `archive/` if needed.
- **delete** — only on explicit per-file confirmation; otherwise default to archive.

Never auto-archive or auto-delete without confirmation — `--decay` surfaces, user decides.

### Notes

- Computed strength is not persisted — recompute every run from the live frontmatter + mtime, so changes to the formula or half-lives apply without a migration.
- Missing decay fields are NOT drift; treat them as "never recalled, age = time since created/mtime" and score accordingly.
- The recall-tracking hook (`Memory.Pack/hooks/memory-recall.sh`) writes `last_recalled` and `recall_count` asynchronously when Claude Reads a memory file — so a memory recently read but not yet stamped may race. If `recall_count` seems off by one, don't flag; trust the next audit.
