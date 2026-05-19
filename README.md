# Memory.Pack

A session-continuity + auto-memory engine for [Claude Code](https://claude.com/claude-code).

It wires a set of hooks into Claude Code so that, across sessions, Claude:

- **carries context forward** — a summary of your previous session is replayed
  into the next one (no more starting from zero);
- **remembers durably** — a per-project memory store captures decisions,
  learnings, and project state, and the relevant pieces are auto-recalled by
  full-text relevance at the start of each turn;
- **stays out of the way** — foreign hooks, unrelated `settings.json` keys, and
  any existing statusline are never touched; everything is idempotent and
  reversible.

It is a real `git clone && ./install.sh` application — the installer only
places files and wires `~/.claude/settings.json`; it never patches your shell,
your repos, or Claude Code itself.

---

## Requirements

| Tool | Why |
|------|-----|
| `bash` `git` `python3` `jq` `sqlite3` `node` | preflighted by the installer; install must abort without them |
| Claude Code | the host these hooks run in |

- **macOS and Linux** are supported directly.
- **Windows: use WSL2** — the engine runs unchanged there. A native PowerShell
  port is intentionally not provided.
- `python3` must have the stdlib `sqlite3` with FTS5 (true on all standard
  builds). Any `md5sum`/`md5` works (GNU, BSD, or uutils).

Install the prerequisites if needed:

```sh
# Debian / Ubuntu
sudo apt-get install -y bash git python3 jq sqlite3 nodejs

# macOS (Homebrew)
brew install bash git python jq sqlite node
```

---

## Install

```sh
git clone https://github.com/hophuongnam/memory.pack.git
cd memory.pack
./install.sh
```

Non-interactive (CI / scripted hosts):

```sh
./install.sh --yes
```

That's it. **Open a new Claude Code session** afterward — hooks are read at
session start, so the current session won't have them.

### Options

| Flag | Effect |
|------|--------|
| `--yes`, `-y` | assume yes; no prompts |
| `--prefix DIR` | install the engine to `DIR` (default: `~/.memory-pack`, or `$MEMORY_PACK_HOME`) |
| `--with-sdk` | also install `@anthropic-ai/claude-agent-sdk` engine-local (enables replay — see [Replay](#replay--the-sdk)) |
| `--check` | preflight dependencies only, then exit (no changes) |
| `--uninstall` | remove Memory.Pack (see [Uninstall](#uninstall)) |
| `--purge` | with `--uninstall`: also delete the engine directory |

### What the installer does (all idempotent, all reversible)

1. Preflights `bash git python3 jq sqlite3 node`.
2. Copies the engine to the prefix (`~/.memory-pack` by default) — no `.git`,
   no runtime state.
3. Merges **11 hook registrations** + `env.MEMORY_PACK_HOME` into
   `~/.claude/settings.json`. Your existing hooks and any unrelated keys are
   left exactly as they were; a one-time pristine backup is written to
   `~/.claude/settings.json.mp-bak`.
4. Symlinks `~/.claude/statusline-command.sh` → the engine's statusline and
   wires `.statusLine` (a pre-existing real statusline of yours is never
   clobbered).
5. Appends a single `SCHEMA.md` pointer line to `~/.claude/CLAUDE.md` (once).
6. Builds a local full-text (SQLite FTS5) index of your memory store.

Re-running `./install.sh` is safe and is also the **upgrade path**:

```sh
cd memory.pack && git pull && ./install.sh
```

---

## After install — what you'll see

- **New sessions** open with a short replayed summary of your previous session.
- Claude **writes memories** automatically (periodically, and at session end)
  into a per-project store at
  `~/.claude/projects/<project-slug>/memory/`.
- Relevant memories are **auto-surfaced** at the top of a turn when they match
  what you're working on.
- The status line shows Memory.Pack state.

Memories are plain Markdown files with small YAML frontmatter — readable,
grep-able, and yours. The contract (types, frontmatter, lifecycle) is
[`SCHEMA.md`](SCHEMA.md).

---

## Uninstall

```sh
~/.memory-pack/install.sh --uninstall          # or ./install.sh --uninstall from the clone
```

This removes the 11 hooks, `env.MEMORY_PACK_HOME`, the `.statusLine` entry, and
the statusline symlink — and **only** those. Foreign hooks, foreign env keys,
and a clean host's `settings.json` are restored exactly as they were
pre-install. Your memory store is left intact.

Also delete the installed engine directory:

```sh
~/.memory-pack/install.sh --uninstall --purge
```

To also remove the memories, delete `~/.claude/projects/*/memory/` yourself
(the uninstaller never touches your data).

---

## Replay & the SDK

Replay (the "carry context into the next session" feature) uses
`@anthropic-ai/claude-agent-sdk`. If it isn't found, **the engine still works**
— memory writing, recall, full-text search, and the status line are all
unaffected; only replay/boot-context no-ops until the SDK is available.

Enable it any one of these ways:

```sh
./install.sh --with-sdk                          # engine-local install
npm i -g @anthropic-ai/claude-agent-sdk          # global
export CLAUDE_AGENT_SDK=/path/to/sdk.mjs         # point at an existing copy
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `install.sh` aborts on missing deps | install them (see [Requirements](#requirements)); re-run `./install.sh --check` to confirm |
| Hooks don't seem active | open a **new** Claude Code session — hooks load at session start |
| Warning: `claude-agent-sdk NOT found` | expected without the SDK; see [Replay](#replay--the-sdk). Everything except replay still works |
| Host can't reach github (no HTTPS/443) | on a machine with access: `git archive HEAD \| gzip > mp.tgz`, copy it over (e.g. `scp`), `tar -xzf` it, then run `./install.sh` from the extracted tree |
| Did it install correctly? | `./install.sh --check` (deps); the test suite under `tests/` validates the engine itself |

---

## Layout

| Path | What |
|------|------|
| `install.sh` | the installer / uninstaller |
| `hooks/` | the hook scripts (the engine proper) |
| `index/` | the FTS5 indexer + search CLI |
| `install/hooks.manifest.json` | canonical list of the 11 hook registrations |
| `statusline-command.sh` | the status line |
| [`SCHEMA.md`](SCHEMA.md) | **the** memory contract: types, frontmatter, lifecycle |
| [`docs/flow.md`](docs/flow.md) | architecture / data-flow walkthrough |
| [`CLAUDE.md`](CLAUDE.md) | engine development & maintenance guide (for contributors) |

After install, the live engine lives at the prefix (default `~/.memory-pack`);
the clone is only needed to install or upgrade.

---

## Notes

- The engine is path- and host-portable: relocate it with `--prefix` or
  `$MEMORY_PACK_HOME`; nothing hard-codes an install path.
- Everything the installer writes is reversible and foreign-safe by design,
  and the install/uninstall round trip is regression-tested.
- This is tooling for Claude Code sessions; it stores summaries and notes you
  (via Claude) choose to keep. Review your memory store like any other notes.
