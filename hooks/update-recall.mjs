#!/usr/bin/env node
// Bump `last_recalled` and `recall_count` in a memory file's frontmatter.
// Invoked by `memory-recall.sh` (PostToolUse hook) when Claude Reads a
// file under `~/.claude/projects/*/memory/`. Atomic write (tmp + rename).
// Idempotent per-day per-session via a sidecar marker so a single session
// that re-reads the same memory doesn't inflate recall_count.

import { readFileSync, writeFileSync, renameSync, existsSync, closeSync, openSync, readdirSync, statSync, unlinkSync, utimesSync } from 'node:fs';
import { dirname, basename, join } from 'node:path';

const [, , memoryPath, sessionId] = process.argv;
if (!memoryPath) process.exit(0);

// Session-level dedup: one recall bump per (memory, session). Re-reads
// within the same session still refresh `last_recalled` but won't inflate
// `recall_count`. Marker lives alongside the memory file, prefixed with `.`
// and using the `.touched` extension so it doesn't look like an orphan
// `.md` memory file to `memory-lint`.
const memDir = dirname(memoryPath);
const markerName = `.recalled-${sessionId || 'nosession'}-${basename(memoryPath, '.md')}.touched`;
const markerPath = join(memDir, markerName);
const alreadyBumpedThisSession = sessionId && existsSync(markerPath);

// Opportunistic cleanup: purge session markers older than 2 days so they
// don't accumulate indefinitely. Cheap — runs at most once per Read.
try {
  const twoDaysAgo = Date.now() - 2 * 24 * 60 * 60 * 1000;
  for (const entry of readdirSync(memDir)) {
    if (!entry.startsWith('.recalled-') || !entry.endsWith('.touched')) continue;
    const p = join(memDir, entry);
    try {
      if (statSync(p).mtimeMs < twoDaysAgo) unlinkSync(p);
    } catch {
      // ignore — file may have been removed by another hook in flight
    }
  }
} catch {
  // ignore
}

let body;
let origStat;
try {
  body = readFileSync(memoryPath, 'utf8');
  origStat = statSync(memoryPath);
} catch {
  process.exit(0);
}

// Parse frontmatter: must start with `---\n`, ends at next `---` on its own line.
if (!body.startsWith('---\n')) process.exit(0);
const end = body.indexOf('\n---\n', 4);
if (end < 0) process.exit(0);

const fmBlock = body.slice(4, end);
const rest = body.slice(end + 5);

const today = new Date().toISOString().slice(0, 10);

// Parse simple `key: value` lines. Memory frontmatter is flat YAML — no nesting.
const lines = fmBlock.split('\n');
const keys = new Map();
const order = [];
for (const line of lines) {
  const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$/);
  if (m) {
    keys.set(m[1], m[2]);
    if (!order.includes(m[1])) order.push(m[1]);
  }
}

const prevCount = parseInt(keys.get('recall_count') || '0', 10) || 0;
const newCount = alreadyBumpedThisSession ? prevCount : prevCount + 1;

keys.set('last_recalled', today);
keys.set('recall_count', String(newCount));
for (const k of ['last_recalled', 'recall_count']) {
  if (!order.includes(k)) order.push(k);
}

const newFm = order.map((k) => `${k}: ${keys.get(k)}`).join('\n');
const out = `---\n${newFm}\n---\n${rest}`;

// Preserve original mtime so `/memory-lint --decay` still sees the real
// "last substantive write" time for legacy memories that lack a `created`
// frontmatter field (the decay scorer falls back to mtime when `created`
// is absent per SCHEMA.md). Without this, the hook would bump mtime on
// every Read and make every legacy memory look perpetually fresh, breaking
// decay scoring entirely. (Side note: this does NOT close the Edit-tool
// race — Edit's freshness check compares content, not mtime, and the
// recall bump rewrites content + changes ctime via the rename. The
// Bash+Python workaround in feedback_memory_edit_recall_race.md is what
// actually sidesteps Edit; see that memory for details.)
const tmp = `${memoryPath}.recall.tmp`;
writeFileSync(tmp, out);
try {
  utimesSync(tmp, origStat.atime, origStat.mtime);
} catch {
  // non-fatal
}
renameSync(tmp, memoryPath);

if (sessionId && !alreadyBumpedThisSession) {
  try {
    closeSync(openSync(markerPath, 'w'));
  } catch {
    // non-fatal
  }
}
