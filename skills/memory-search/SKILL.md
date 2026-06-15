---
name: memory-search
description: Full-text search across all auto-memory files (active + archive, all projects) using SQLite FTS5 with BM25 ranking. Use when investigating a recurring problem, when something feels familiar from prior work, when you'd otherwise read MEMORY.md indices one by one, or when the user types /memory-search or asks to "search memory", "find a memory about X", "look in the archive for Y".
---

# Memory Search

Cross-project keyword search over the entire auto-memory corpus — every memory file under `~/.claude/projects/*/memory/`, including everything in `archive/` subdirectories. Backed by a SQLite FTS5 index at `$MEMORY_PACK_HOME/index/search.db`, kept fresh by PostToolUse + SessionEnd hooks.

This complements (does not replace) `MEMORY.md`, the per-project recall flow, and the **auto-injection layer**:
- `MEMORY.md` is loaded into context automatically. It only carries active memories. Use it for the current project's known-relevant items.
- The **auto-injection hook** (`Memory.Pack/hooks/memory-search-inject.sh`, UserPromptSubmit) tokenizes every user prompt and silently injects up to 3 strong-BM25 hits as a `## Memory hits` block. Each hit is annotated `[bm25=X · cov=Y/N · status · type · project]` — the `cov` field shows how many of the query's distinct tokens the doc matches (a doc with `cov=2/7` matched 2 of 7 prompt tokens). Reads with low coverage relative to the query are filtered out (default ≥30%) to dampen the BM25-OR coverage artifact where short docs matching all query terms once outrank focused docs matching a subset heavily. **Sparse follow-up prompts** ("fix that", "any other ideas?") trigger the transcript-aware fallback — the hook pulls keywords from the last ~50 turns of text+thinking content so even contextless follow-ups can match. **Meaty prompts** (≥5 distinct tokens after stopword filtering) skip the transcript blend so they aren't diluted by topic drift.

**Reading a promoted-from-archive memory**: if you Read an archived memory and it's the third distinct session that's done so, `update-recall.mjs` will atomically promote it back to active, update MEMORY.md, and re-sync the search index — all backgrounded. You'll see a `.archive-promote.log` entry at the project's memory dir if you want to audit the move. To trigger this manually for a specific archived hit, just Read it (the recall hook handles the rest); no explicit promotion command exists.
- Manual `memory-search` (this skill) is **on-demand** for digging deeper: re-querying with different terms, applying filters (`--type`, `--status`, `--project`), surfacing more than 3 hits, or hunting things the auto-injector's stopword filter missed.

## When to use

- A current problem feels like one you've solved before but isn't in `MEMORY.md` (probably archived).
- You're starting work in project A but a similar issue was solved in project B.
- The user mentions a topic ("the SQLite WAL thing", "that tonic body issue") and you want to verify whether prior context exists before asking them to re-explain.
- You're about to write a new memory and want to check whether a similar one already exists (active or archived) — so you update instead of duplicating.

## When NOT to use

- The answer is obviously in code or `git log` — don't search memory for things memory doesn't track (file paths, recent diffs, line numbers).
- A single grep over the current project's memory dir would do — `grep -r "term" ~/.claude/projects/<slug>/memory/` is faster for one project, one keyword.

## How to invoke

Run the CLI directly via Bash:

```bash
$MEMORY_PACK_HOME/index/search-memories.py <query>
```

The query is **FTS5 MATCH syntax**:

| Pattern | Meaning |
|---|---|
| `sqlite WAL` | both terms (implicit AND) |
| `sqlite OR postgres` | either |
| `"exact phrase"` | phrase match |
| `sql*` | prefix (trailing star only) |
| `type:feedback sqlite` | column filter (FTS5 native) |

Filter flags:

| Flag | Effect |
|---|---|
| `--status archived` | only archived memories |
| `--status active` | only active memories |
| `--type feedback` (or user/project/reference/session) | filter by type — `session` matches the auto-indexed `sessions.log.md` files; the CLI accepts any string so future types Just Work |
| `--project Mira` | substring match on project slug |
| `--limit N` | cap results (default 20) |
| `--paths-only` | one path per line, for piping into Read |
| `--json` | structured output |

## Reading the output

Default output per hit:
```
[bm25-score] /abs/path/to/file.md
  type=feedback status=archived project=-Users-namhp-Resilio-Sync-Mira
  name: <frontmatter name>
  desc: <frontmatter description>
  snip: …context snippet with «matched terms» highlighted…
```

**BM25 is negative-log-odds — lower (more negative) = better match.** Results are pre-sorted; you don't need to re-rank. A spread like `-12, -11, -7` means the top hits are decisively better; a flat spread like `-6, -6, -6` means the query was ambiguous.

After getting hits, decide which files actually warrant a `Read`:
- The `desc` line is the frontmatter `description:` — a one-line relevance hook by design (per `SCHEMA.md`). If the description doesn't address what you're looking for, skip the Read.
- Reading an archived memory does **not** auto-resurrect it (resurrection is filename-collision only, on Write). If you want to promote a useful archived memory back to active, the user has to confirm — surface the path and ask.

## Examples

```bash
# Find anything about SQLite WAL across all projects, all time
$MEMORY_PACK_HOME/index/search-memories.py sqlite WAL

# Just feedback memories that mention tonic
$MEMORY_PACK_HOME/index/search-memories.py --type feedback tonic

# Search only the archive for anything about dispatch
$MEMORY_PACK_HOME/index/search-memories.py --status archived dispatch

# Find Mira-specific axum body issues, top 3
$MEMORY_PACK_HOME/index/search-memories.py --project Mira --limit 3 axum body

# Pipe top 5 matching paths into a follow-up Read
$MEMORY_PACK_HOME/index/search-memories.py --limit 5 --paths-only "exact phrase"
```

## When the index might be stale

The PostToolUse hook updates per-file on every Write/Edit/MultiEdit. The SessionEnd hook does a full incremental reconcile. So in normal use the index is always current.

If you suspect drift (recent `mv` outside Claude, manual filesystem edit, just installed the system), force a sync:

```bash
$MEMORY_PACK_HOME/index/index-memories.py            # incremental
$MEMORY_PACK_HOME/index/index-memories.py --rebuild  # nuke and rebuild
```

`--rebuild` over ~700 memories runs in <1s.

## Don't drift from the schema

Search returns ALL files matching the index walk rules — including any orphans. If a search hit looks malformed (no `name`/`description`, weird path, lives outside any `memory/` dir), it's a candidate for `/memory-lint`, not for trust. The search index is honest about what's on disk; it does not enforce schema.
