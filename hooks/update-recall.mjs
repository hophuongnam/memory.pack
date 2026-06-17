#!/usr/bin/env node
// Bump `last_recalled` and `recall_count` in a memory file's frontmatter.
// Invoked by `memory-recall.sh` (PostToolUse hook) when Claude Reads a
// file under `~/.claude/projects/*/memory/`. Atomic write (tmp + rename).
// Idempotent per-day per-session via a sidecar marker so a single session
// that re-reads the same memory doesn't inflate recall_count.

import { readFileSync, writeFileSync, renameSync, existsSync, closeSync, openSync, readdirSync, statSync, unlinkSync, utimesSync, appendFileSync } from 'node:fs';
import { dirname, basename, join } from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { fmParse, fmSetInPlace, fmSerialize } from './_lib.mjs';

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

// Parse frontmatter via the shared helper (_lib.mjs fmParse): every key is
// read leading-whitespace tolerant, so the stock system-prompt's nested
// `metadata: { type }` shape and CC's intermittent `node_type:` injection
// are both parsed. The keys map feeds the archive-promote path below
// (description/type/recall_count); it is NOT used to re-serialize. We never
// restructure the file — shapes are tolerated on read, never mutated (see
// SCHEMA.md). The Python indexer (`index-memories.py`) parses the same way
// via `k.strip()`, so `type` resolves from any shape regardless of this hook.
const fm = fmParse(body);
if (!fm) process.exit(0);
const { lines, keys, rest } = fm;

const today = new Date().toISOString().slice(0, 10);

const prevCount = parseInt(keys.get('recall_count') || '0', 10) || 0;
const newCount = alreadyBumpedThisSession ? prevCount : prevCount + 1;

// In-place edit (shared fmSetInPlace): rewrite ONLY the two counter lines,
// preserving each line's existing indentation; append at column 0 if
// absent. Every other byte of the frontmatter — key order, the `metadata:`
// wrapper, indentation, `node_type`, blank lines — is left exactly as the
// author/harness wrote it.
fmSetInPlace(lines, 'recall_count', String(newCount));
fmSetInPlace(lines, 'last_recalled', today);

const out = fmSerialize(lines, rest);

// ponytail: byte-identical re-read → skip the write entirely. A tmp+rename
// changes the inode/ctime even when the bytes don't, which busts the Edit
// tool's post-read freshness check (the "modified since read" race — see
// feedback_memory_edit_recall_race.md). Same-session re-reads land here
// (count already bumped, last_recalled already today), so this makes a
// re-read a true no-op and stops pointless file churn. The first read of a
// session still bumps+writes; that Read→Edit window is the residual race the
// Bash+Python workaround covers.
if (out === body) process.exit(0);

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

// === Auto-promote on recall threshold ===========================
// If this Read landed on an archived memory and the bumped recall_count
// clears PROMOTION_THRESHOLD, atomically move the file back to active and
// add it to MEMORY.md. The threshold is absolute (not delta-since-archive)
// because the schema doesn't track an `archived_at_recall_count` field —
// see SCHEMA.md "Auto-promote on recall threshold". Defensive throughout:
// any failure leaves the recall bump intact and the file in archive.
const PROMOTION_THRESHOLD = parseInt(process.env.MEMORY_PROMOTION_THRESHOLD || '3', 10);
const isArchived = memoryPath.includes('/memory/archive/');
if (isArchived && newCount >= PROMOTION_THRESHOLD) {
  try {
    promoteFromArchive(memoryPath, keys, newCount, markerName);
  } catch (err) {
    try {
      const log = archivePromoteLog(memoryPath);
      appendFileSync(log, `${new Date().toISOString()} error ${basename(memoryPath)} (${err && err.message ? err.message : String(err)})\n`);
    } catch {}
  }
}

function archivePromoteLog(memoryPath) {
  // Log lives at <active-dir>/.archive-promote.log alongside the existing
  // .archive-resurrect.log, regardless of whether the path is currently
  // inside archive/ or already promoted out.
  const activeDir = dirname(memoryPath).replace(/\/archive$/, '');
  return join(activeDir, '.archive-promote.log');
}

function promoteFromArchive(archivePath, keys, recallCount, markerNameForMove) {
  const activePath = archivePath.replace('/memory/archive/', '/memory/');
  const log = archivePromoteLog(archivePath);
  const stamp = new Date().toISOString();

  if (existsSync(activePath)) {
    appendFileSync(log, `${stamp} skip-collision ${basename(archivePath)} (active path already exists)\n`);
    return;
  }

  // Atomic move. renameSync is atomic on the same filesystem (always true
  // here — archive/ is a subdir of memory/).
  renameSync(archivePath, activePath);

  // Move the session-recall sidecar so a same-session re-Read still
  // dedups correctly at the new path.
  try {
    const oldMarker = join(dirname(archivePath), markerNameForMove);
    const newMarker = join(dirname(activePath), markerNameForMove);
    if (existsSync(oldMarker)) renameSync(oldMarker, newMarker);
  } catch {
    // non-fatal
  }

  // Insert into MEMORY.md under the type-appropriate section.
  let indexUpdated = false;
  try {
    indexUpdated = updateMemoryIndex(activePath, keys);
  } catch (err) {
    appendFileSync(log, `${stamp} index-update-failed ${basename(activePath)} (${err && err.message ? err.message : String(err)})\n`);
  }

  // Re-sync the FTS5 index: delete archive entry, insert active entry.
  // Backgrounded so the recall hook returns instantly.
  try {
    const indexer = join(dirname(fileURLToPath(import.meta.url)), '..', 'index', 'index-memories.py');
    if (existsSync(indexer)) {
      spawn('python3', [indexer, '--file', archivePath, '--quiet'], { detached: true, stdio: 'ignore' }).unref();
      spawn('python3', [indexer, '--file', activePath, '--quiet'], { detached: true, stdio: 'ignore' }).unref();
    }
  } catch {
    // non-fatal — SessionEnd reconcile will catch it
  }

  appendFileSync(
    log,
    `${stamp} promote ${basename(archivePath)} (recall_count=${recallCount}, index_updated=${indexUpdated})\n`
  );
}

function updateMemoryIndex(activePath, keys) {
  const memDir = dirname(activePath);
  const indexPath = join(memDir, 'MEMORY.md');
  if (!existsSync(indexPath)) return false;

  const filename = basename(activePath);
  const today = new Date().toISOString().slice(0, 10);
  let desc = keys.get('description') || '';
  // Strip surrounding quotes if any (frontmatter parsing keeps them).
  desc = desc.replace(/^["']|["']$/g, '');
  if (desc.length > 120) desc = desc.slice(0, 117) + '…';
  const type = (keys.get('type') || 'feedback').toLowerCase();

  const sectionMap = {
    user: '## User & feedback',
    feedback: '## User & feedback',
    project: '## Projects',
    reference: '## Infrastructure & reference',
  };
  const section = sectionMap[type] || '## User & feedback';

  let content = readFileSync(indexPath, 'utf8');

  // Idempotency: if the filename already appears in the index, do nothing.
  // Match `(<filename>)` or `[<filename>]` to catch any link form.
  if (content.includes(`(${filename})`) || content.includes(`[${filename}]`)) {
    return false;
  }

  const entry = `- ${today} [${filename}](${filename}) — ${desc}`;
  const lines = content.split('\n');
  const sectionIdx = lines.findIndex((l) => l.trim() === section);

  if (sectionIdx < 0) {
    // Section missing — append at end.
    while (lines.length > 0 && lines[lines.length - 1].trim() === '') lines.pop();
    lines.push('', section, entry);
  } else {
    // Find the end of this section: next `## ` heading or EOF.
    let endIdx = sectionIdx + 1;
    while (endIdx < lines.length && !lines[endIdx].startsWith('## ')) endIdx++;
    // Trim trailing blank lines inside the section.
    while (endIdx > sectionIdx + 1 && lines[endIdx - 1].trim() === '') endIdx--;
    lines.splice(endIdx, 0, entry);
  }

  const out = lines.join('\n');
  const tmp = `${indexPath}.promote.tmp`;
  writeFileSync(tmp, out);
  renameSync(tmp, indexPath);
  return true;
}
