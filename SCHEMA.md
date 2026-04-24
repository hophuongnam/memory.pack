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
