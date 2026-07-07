#!/usr/bin/env node
// Auto-resurrect an archived memory when a new memory is written under the
// same slug. Invoked by `archive-resurrect.sh` (PostToolUse on Write) when
// Claude writes to `~/.claude/projects/<slug>/memory/<basename>.md` and an
// archive copy exists at `<same-dir>/archive/<basename>.md`.
//
// Behavior (no prompting, no body merging — see SCHEMA.md "Auto-resurrect"):
//   1. New body wins (Claude just wrote the canonical version).
//   2. Inherit `created` and `recall_count` from the archive into the new
//      file's frontmatter — preserves the "this lesson recurred" signal.
//   3. Stamp `last_reviewed: <today>` so the resurrected memory doesn't
//      immediately re-trigger decay.
//   4. Delete the archive copy.
//   5. Append a one-line audit log to `<dir>/.archive-resurrect.log`.
//
// Exact-slug match only. Paraphrased slugs are intentionally not caught —
// false positives would silently destroy a valid new memory by inheriting
// wrong metadata.

import { readFileSync, writeFileSync, renameSync, existsSync, statSync, unlinkSync, appendFileSync } from 'node:fs';
import { dirname, basename, join } from 'node:path';
import { fmParse, fmSetInPlace, fmSerialize } from './_lib.mjs';

const [, , memoryPath] = process.argv;
if (!memoryPath) process.exit(0);

// Only act on memory files. Skip MEMORY.md, SESSIONS.md, etc.
const baseName = basename(memoryPath);
if (
  baseName === 'MEMORY.md' ||
  baseName === 'SESSIONS.md' ||
  baseName === 'sessions.log.md' ||
  baseName === 'PENDING_MEMORIES.md' ||
  baseName === 'SCHEMA.md' ||
  baseName.startsWith('.')
) {
  process.exit(0);
}
if (!baseName.endsWith('.md')) process.exit(0);

const memDir = dirname(memoryPath);

// Don't recurse into archive itself: if the path is `.../memory/archive/foo.md`,
// there's no `<dir>/archive/archive/foo.md` to merge from. Skip.
if (basename(memDir) === 'archive') process.exit(0);

const archivePath = join(memDir, 'archive', baseName);
if (!existsSync(archivePath)) process.exit(0);
if (!existsSync(memoryPath)) process.exit(0);

let newBody, archiveBody;
try {
  newBody = readFileSync(memoryPath, 'utf8');
  archiveBody = readFileSync(archivePath, 'utf8');
} catch {
  process.exit(0);
}

// Both files must have well-formed frontmatter for safe metadata transfer.
// Shared fmParse (_lib.mjs): whitespace-tolerant key reads. The legacy
// local parser collected only column-0 keys and re-serialized the file
// from that map — nested `metadata:` children and any unmatched line were
// silently DELETED from the resurrected memory. The shared helpers set
// the three inherited keys IN PLACE and keep every other byte verbatim
// (same never-reshape contract as update-recall.mjs; SCHEMA.md).
const newFm = fmParse(newBody);
const archiveFm = fmParse(archiveBody);

// If either side is malformed, do nothing. The new write stays as-is and
// the archive copy is left untouched for a human to inspect.
if (!newFm || !archiveFm) process.exit(0);

const today = new Date().toISOString().slice(0, 10);

// Inherit metadata from archive. `created` and `recall_count` carry the
// recurrence signal forward; `last_recalled` from the pre-archive era is
// stale, so we drop it (the recall hook will repopulate on next Read).
const archivedCreated = archiveFm.keys.get('created');
const archivedRecallCount = archiveFm.keys.get('recall_count');

if (archivedCreated) fmSetInPlace(newFm.lines, 'created', archivedCreated);
if (archivedRecallCount) fmSetInPlace(newFm.lines, 'recall_count', archivedRecallCount);
fmSetInPlace(newFm.lines, 'last_reviewed', today);

const out = fmSerialize(newFm.lines, newFm.rest, newFm.eol);

// Atomic write: tmp + rename.
const tmp = `${memoryPath}.resurrect.tmp`;
try {
  writeFileSync(tmp, out);
  renameSync(tmp, memoryPath);
} catch {
  try { unlinkSync(tmp); } catch {}
  process.exit(0);
}

// Compute days_in_archive for the audit line.
let daysInArchive = '?';
try {
  const archStat = statSync(archivePath);
  const ageMs = Date.now() - archStat.mtimeMs;
  daysInArchive = String(Math.round(ageMs / 86400000));
} catch {}

// Delete archive copy. If this fails we leave the duplicate; memory-lint
// will surface it on next audit.
try {
  unlinkSync(archivePath);
} catch {}

// Audit log. Dotfile prefix so memory-lint skips it.
const logPath = join(memDir, '.archive-resurrect.log');
const stamp = new Date().toISOString();
const created = archivedCreated || '?';
const recallCount = archivedRecallCount || '0';
const logLine = `${stamp} resurrect ${baseName} (created=${created}, recall_count=${recallCount}, days_in_archive=${daysInArchive})\n`;
try {
  appendFileSync(logPath, logLine);
} catch {}
