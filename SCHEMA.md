# Auto-Memory Schema (canonical)

This file defines the contract for the **per-project auto-memory stores** that live under `~/.claude/projects/<slugified-cwd>/memory/`. It is the single source of truth across **all projects** — do not fork it into individual memory dirs.

It is not itself a memory. It has no frontmatter and is not indexed by any `MEMORY.md`. It exists so the typing rules that govern memory writes are visible and user-editable, rather than buried only in the system prompt.

If this file disagrees with the system prompt's `# auto memory` block, **the system prompt wins** — but flag the drift so one or the other gets updated. See the Evolution section at the bottom.

## File layout (per project)

```
~/.claude/projects/<slugified-cwd>/memory/
├── MEMORY.md        # one-line index, grouped by type (not chronological)
└── <type>_<slug>.md # one memory per file
```

- Filenames: `<type>_<short_slug>.md`. Lowercase, underscores, no dates.
- One memory per file. Never inline multiple memories.
- `MEMORY.md` entries are one line each, under 150 chars: `- YYYY-MM-DD [file](file) — one-line hook`.
- There is **no per-project `SCHEMA.md`** — the canonical schema lives at `~/Resilio.Sync/Memory.Pack/SCHEMA.md` and applies to every project.

## Frontmatter contract

Every memory file begins with YAML frontmatter. Required fields:

```yaml
---
name: {{short human title}}
description: {{one-line relevance hook — used by future sessions to decide whether to load this memory}}
type: {{user | feedback | project | reference}}
---
```

### Harness-managed field

- `originSessionId` — the Claude Code **harness itself** auto-appends this field on every Write/Edit to a memory file if the frontmatter doesn't already contain it, stamping the current session ID. Confirmed by searching the 2.1.x binary for `/^originSessionId:/m.test`. It is NOT written by any hook in `Memory.Pack/hooks/`. Consequences:
  - **Do not flag as drift.** `/memory-lint` must treat it as legitimate metadata.
  - **Do not hand-remove.** The harness will re-add it on the next edit, so removal is futile and just churns the file.
  - **Do not seed it manually.** The harness handles it; writing it yourself is harmless but pointless.
  - The value only records *which session most recently touched a fresh copy of the file*, not the original author — subsequent sessions that edit the file don't overwrite an existing `originSessionId`, but removing and re-editing will stamp the current session.

### Decay-tracking fields (optional)

These four fields drive Ebbinghaus-style decay scoring in `/memory-lint --decay`. All optional — memories without them are treated as maximally strong on first audit, so adoption is zero-migration.

- `created` — ISO date (`YYYY-MM-DD`) when the memory was first written. Seeded by the author; never rewritten.
- `last_recalled` — ISO date; auto-updated by `Memory.Pack/hooks/memory-recall.sh` every time a memory file is Read mid-session.
- `recall_count` — integer; cumulative reinforcement count incremented alongside `last_recalled`.
- `last_reviewed` — ISO date; set by `/memory-lint` when the user confirms a memory is still valid.

Missing fields are NOT drift. `/memory-lint --decay` treats absent `last_recalled`/`last_reviewed` as equivalent to `created`; absent `created` falls back to the file's mtime.

No other frontmatter fields are recognized. Anything beyond `name`/`description`/`type`/`originSessionId`/`created`/`last_recalled`/`recall_count`/`last_reviewed` is drift and should be flagged.

## Decay model (used by `/memory-lint --decay`)

Ebbinghaus-inspired retention scoring. Every memory has a computed **strength** in `(0, 1]`:

```
strength = exp( -Δt / (half_life × (1 + ln(1 + recall_count))) )
```

where `Δt = today - max(last_recalled, last_reviewed, created)` in days, and reinforcement flattens the decay curve through the `ln(1 + recall_count)` term.

Half-lives by type:

| type | half-life |
|---|---|
| `user`, `feedback` | 180 days |
| `reference` | 90 days |
| `project` | 21 days |

Thresholds used by `/memory-lint --decay`:
- `strength < 0.3` → surface in audit as "decayed, needs review"
- `strength < 0.1` AND no recall in 60d → propose for archive (move to `memory/archive/`, drop from `MEMORY.md`)

Archive is a proposal, not auto-action. The lint run surfaces candidates and waits for per-item user confirmation before touching any file.

## Auto-resurrect on slug collision

The archive is not a graveyard — it is a recurrence detector. `Memory.Pack/hooks/archive-resurrect.sh` (PostToolUse on Write) fires every time a memory file is written and silently inherits archived metadata when the new file's basename collides with an entry in `<memory-dir>/archive/`. No prompt, no merge of body content.

**Trigger:** Write to `~/.claude/projects/<slug>/memory/<basename>.md` AND `<same-dir>/archive/<basename>.md` exists.

**Action (atomic, in-place rewrite of the new file):**
1. Inherit `created` from the archived file — preserves the original "first learned" date.
2. Inherit `recall_count` from the archived file — preserves the recurrence signal (a memory archived with `recall_count: 5` and now re-written stays at 5; the recall hook will continue to bump it from there).
3. Stamp `last_reviewed: <today>` so the freshly-resurrected memory does not immediately re-trigger decay.
4. Drop `last_recalled` carried over from the pre-archive era — it is stale; the recall hook will repopulate on next Read.
5. Delete the archive copy.
6. Append a one-line audit entry to `<memory-dir>/.archive-resurrect.log` (dotfile, skipped by `/memory-lint`).

**Exact-slug match only.** Paraphrased slugs (e.g. archived `feedback_sqlite_wal.md` vs new `feedback_sqlite_wal_required.md`) are intentionally not caught. False positives — silently destroying a valid new memory by inheriting wrong metadata — would be worse than false negatives, which the user can fix manually with `mv archive/<file> ./` and an Edit.

**Why no body merge.** The new write is, by construction, Claude's current understanding. The archived body is by definition stale (it crossed `strength < 0.1` to be archived). Auto-merging risks re-introducing contradicted information; letting the new body win is honest about which version is canonical now. The recurrence signal lives in the metadata, not the prose.

**Interaction with `/memory-lint --decay`.** A resurrected memory looks like a high-strength memory with an old `created` date — exactly the right shape. The strength formula already handles it: `Δt` is anchored to `last_reviewed` (today), so strength resets to ~1; `recall_count` carries over and continues to flatten the future decay curve.

## Auto-promote on recall threshold

Archive is also not a one-way gate. `Memory.Pack/hooks/update-recall.mjs` (backgrounded by `memory-recall.sh` PostToolUse on Read) fires when an **archived** memory is Read mid-session, bumps `recall_count` and `last_recalled` like any other recall, and — if the post-bump `recall_count` clears `MEMORY_PROMOTION_THRESHOLD` (default `3`) — atomically moves the file out of `archive/` and back into the active memory dir.

**Trigger:** Read of `~/.claude/projects/<slug>/memory/archive/<basename>.md` AND post-bump `recall_count >= MEMORY_PROMOTION_THRESHOLD`.

**Action (atomic):**
1. Bump `recall_count` and `last_recalled` in the archived file's frontmatter (normal recall flow).
2. `renameSync` the file from `<dir>/archive/<basename>.md` to `<dir>/<basename>.md`.
3. Move the per-session recall sidecar (`.recalled-<sid>-<slug>.touched`) from `archive/` to the active dir so same-session re-Reads still dedup correctly.
4. Insert an entry into `MEMORY.md` under the type-appropriate section (`## User & feedback` / `## Projects` / `## Infrastructure & reference`), idempotent on filename collision.
5. Background-trigger the FTS5 indexer to delete the archive entry and insert the active entry.
6. Append a one-line audit entry to `<memory-dir>/.archive-promote.log` (dotfile, skipped by `/memory-lint`).

**Threshold rationale.** The recall hook is per-session-deduplicated via `.recalled-<sid>-<slug>.touched` sidecars, so `recall_count: 3` represents Read in 3 distinct sessions post-archive. Two-session repeat is plausibly incidental; three is a strong signal the memory is still load-bearing. The threshold is absolute (not delta-since-archive) because the schema does not track an `archived_at_recall_count` field — adding one is possible but not currently warranted. Memories archived with a high pre-archive `recall_count` (e.g. 5) will auto-promote on the first post-archive Read; that is the correct behavior — they were popular before, they're being read again, calling them archived is wrong.

**Collision handling.** If an active file with the same basename already exists at the destination (e.g. user wrote a new memory with the same name while the archived copy was still in archive), promotion is skipped and a `skip-collision` line is appended to the audit log. The active file is the canonical version.

**Failure isolation.** Any error during promotion is caught and logged; the recall bump itself succeeds regardless. Worst case: file stays in archive with the bumped counter, and the next Read in another session retries promotion.

## Indexed non-memory artifacts

The FTS5 search index at `Memory.Pack/index/search.db` (covered separately by the search infrastructure docs) intentionally indexes `sessions.log.md` files in addition to canonical memory files. Sessions logs have **no real frontmatter** — `index/index-memories.py` synthesizes metadata for them (`type: session`, `name: "Session log — <project slug>"`, `description: "Append-only replay summaries…"`) so they participate in search uniformly. Use `--type session` (or `--type !=session` patterns) on the search CLI to filter them in or out. They surface narrative continuity that never got promoted to a memory — useful for cross-session topic recall, less useful for "what's the rule for X" lookups.

## Types

### `user`
**Contains:** the user's role, goals, responsibilities, domain expertise, working style.
**Write when:** you learn something about *who the user is* that will shape how you explain things or what they care about.
**Do not write:** judgments ("user is impatient"), ephemeral moods, role speculation.

### `feedback`
**Contains:** guidance the user has given about *how to work* — corrections AND quiet confirmations of non-obvious approaches.
**Body structure:**
- Lead with the rule
- `**Why:**` — the reason the user gave (often a past incident)
- `**How to apply:**` — when/where the rule kicks in
**Write when:** user corrects you ("no not that") or validates a non-obvious choice by accepting without pushback. Both count. Confirmations are easy to miss — watch for them.
**Do not write:** rules already obvious from the codebase or CLAUDE.md.

### `project`
**Contains:** state/context about ongoing work that is *not derivable from git or the filesystem* — people doing things, why they're doing them, deadlines, stakeholder context.
**Body structure:**
- Lead with the fact or decision
- `**Why:**` — motivation (constraint, deadline, stakeholder ask)
- `**How to apply:**` — how this should shape suggestions
**Write when:** you learn who/why/when. Convert relative dates to absolute at save time ("Thursday" → `2026-03-05`).
**Decay fast.** Project memories age quickly — `/memory-lint` flags expired dates and stale in-progress markers. The `**Why:**` line is what lets future-you judge whether the memory is still load-bearing.

### `reference`
**Contains:** pointers to entities (hosts, services, API keys, external systems) or their stable properties. Think "entity page" in a wiki.
**Write when:** you learn about a resource you'll need to look up again — where bugs are tracked, which dashboard oncall watches, what services run on a given host.
**Prefer cross-references** (`[entity](reference_entity.md)`) over duplicating facts across multiple memories.

## What NOT to save (applies across all types)

- Code patterns, file paths, or architecture that can be re-derived from reading the project
- Git history, recent changes, who-changed-what (use `git log`/`git blame`)
- Debugging solutions or fix recipes — the fix is in the code, the commit message has the context
- Anything already in a `CLAUDE.md`
- Ephemeral task/conversation state

These exclusions apply **even when the user asks to save**. If they ask to save a PR list or activity log, ask what was *surprising* or *non-obvious* — that's the part worth keeping.

## Cross-references

Use relative markdown links between memory files when one memory names an entity that has its own file in the **same project**'s memory dir:

```markdown
Stored on [toolkit](reference_toolkit_server.md):/root/backups/
```

Rationale: reduces duplication, surfaces related memories when one is loaded, and makes `/memory-lint` able to detect broken xrefs.

**Cross-project references** (linking from Project A's memory to Project B's memory) are not supported — each project's memory dir is self-contained. If the same entity shows up in multiple projects, each project gets its own `reference_<entity>.md` or they share by referencing a common external artifact (e.g. the tailnet is a shared resource; each project that needs it keeps its own local `reference_tailscale.md`).

## Index (`MEMORY.md`)

- Always loaded in context — stay under 150 lines (soft cap; the harness hard-truncates at 200 lines or 25KB per the [official docs](https://code.claude.com/docs/en/memory)).
- **Group by type**, not chronological. Suggested sections (use these exact headings for consistency across projects):
  - `## User & feedback`
  - `## Projects`
  - `## Infrastructure & reference`
- Each entry: `- YYYY-MM-DD [file](file) — one-line hook`
- When `MEMORY.md` approaches 150 lines, evict by **lowest decay strength first** (see the decay model below), not by date. A 2024 reference memory with many recalls outranks last week's unused project memory. `/memory-lint --decay` surfaces the weakest candidates for per-item archive/delete under the same reinforce/edit/archive/delete flow it uses in audit mode; the index cap is just another trigger for that flow. Memories without decay-tracking fields fall back to mtime as their Δt, so legacy memories still rank.
- Start `MEMORY.md` with a pointer line: `` See `~/Resilio.Sync/Memory.Pack/SCHEMA.md` for the canonical contract. Shared across all projects. `` (use a code span, not a markdown link — the tilde won't resolve in `[text](~/…)` form).

## Lifecycle operations

| Operation | Tool | Notes |
|---|---|---|
| Write | direct file write + `MEMORY.md` update | Two-step, both required. |
| Update | edit existing file, keep same slug | Preferred over creating a new memory on the same topic. |
| Remove | delete file + remove `MEMORY.md` line | Only when memory is confirmed wrong/stale. |
| Audit | `/memory-lint` | Reports drift grouped as BROKEN/EXPIRED/DRIFT/SUGGEST, waits for per-item approval. Never auto-fixes. |

## Evolution

This schema is user-editable. If you change a type's meaning or add a new field, also update:
1. The system prompt's `# auto memory` block (authoritative — keep the schema here in sync with it)
2. `/memory-lint`'s `SKILL.md` at `~/.claude/skills/memory-lint/SKILL.md` (if the change affects what counts as drift)
3. Any existing memory files across projects that violate the new contract

When the system prompt and this file disagree, the system prompt wins at runtime. But a disagreement is a bug in one of them — resolve it rather than letting drift accumulate.
