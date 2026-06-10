// TDD: archive-resurrect.mjs must NEVER reshape or drop frontmatter it
// didn't write. Its legacy parser collected only column-0 `key: value`
// lines and re-serialized the file from that map — any line that didn't
// match (the stock system-prompt's nested `metadata:` children, comments,
// indented keys) was silently DELETED from the resurrected memory. That is
// the same "tolerate shapes on read, never mutate them" contract
// test_recall_frontmatter_preserve.mjs pins for the recall hook
// (SCHEMA.md; reference_cc_node_type_frontmatter_drift.md).
//
// Fix shape: shared fmParse/fmSetInPlace/fmSerialize in _lib.mjs used by
// BOTH update-recall.mjs and archive-resurrect.mjs — set the three
// inherited keys in place, keep every other byte of the frontmatter.
//
// Behavioral-subprocess pattern: run the REAL archive-resurrect.mjs
// against temp fixtures and assert observable output.

import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const HOOKS = join(HERE, '..', 'hooks');
const RESURRECT = join(HOOKS, 'archive-resurrect.mjs');

let fail = 0;
const ok = (m) => console.log('PASS  ' + m);
const bad = (m, d) => { console.log(`FAIL  ${m}\n      ${d}`); fail++; };
const check = (m, cond, d) => (cond ? ok(m) : bad(m, d));

// --- structural: shared helpers exist and both consumers use them ---------
const lib = await import(join(HOOKS, '_lib.mjs'));
check('_lib.mjs exports fmParse', typeof lib.fmParse === 'function', typeof lib.fmParse);
check('_lib.mjs exports fmSetInPlace', typeof lib.fmSetInPlace === 'function', typeof lib.fmSetInPlace);
check('_lib.mjs exports fmSerialize', typeof lib.fmSerialize === 'function', typeof lib.fmSerialize);
const codeOf = (p) => readFileSync(p, 'utf8').split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
check('archive-resurrect.mjs consumes shared fmParse', /fmParse/.test(codeOf(RESURRECT)),
  'still carries its own parser');
check('update-recall.mjs consumes shared fmParse', /fmParse/.test(codeOf(join(HOOKS, 'update-recall.mjs'))),
  'still carries its own parser');

const SBX = mkdtempSync(join(tmpdir(), 'mp-resurrect-'));
process.on('exit', () => { try { rmSync(SBX, { recursive: true, force: true }); } catch {} });
const memDir = join(SBX, 'memory');
const archDir = join(memDir, 'archive');
mkdirSync(archDir, { recursive: true });

const today = new Date().toISOString().slice(0, 10);
const run = (p) => execFileSync('node', [RESURRECT, p], { stdio: 'pipe' });

// --- case A: flat new + flat archive — inheritance works ------------------
const flatNew = `---
name: lesson_x
description: fresh body wins
type: feedback
---

New body.
`;
const flatArch = `---
name: lesson_x
description: old description
type: feedback
created: 2026-01-01
recall_count: 5
last_recalled: 2026-02-02
---

Old body.
`;
writeFileSync(join(memDir, 'lesson_x.md'), flatNew);
writeFileSync(join(archDir, 'lesson_x.md'), flatArch);
run(join(memDir, 'lesson_x.md'));
let out = readFileSync(join(memDir, 'lesson_x.md'), 'utf8');
check('A: created inherited from archive', /^created: 2026-01-01$/m.test(out), out);
check('A: recall_count inherited from archive', /^recall_count: 5$/m.test(out), out);
check('A: last_reviewed stamped today', new RegExp(`^last_reviewed: ${today}$`, 'm').test(out), out);
check('A: new body wins', out.includes('New body.') && !out.includes('Old body.'), out);
check('A: archive copy deleted', !existsSync(join(archDir, 'lesson_x.md')), 'archive still present');
check('A: stale last_recalled NOT inherited', !/last_recalled: 2026-02-02/.test(out), out);

// --- case B: NESTED new shape — every byte the engine didn't set survives -
const nestedNew = `---
name: lesson_nested
description: nested shape from stock system prompt
metadata:
  type: feedback
  source: conversation
node_type: memory
---

Nested body.
`;
const flatArch2 = `---
name: lesson_nested
description: old
type: feedback
created: 2026-03-03
recall_count: 7
---

Old.
`;
writeFileSync(join(memDir, 'lesson_nested.md'), nestedNew);
writeFileSync(join(archDir, 'lesson_nested.md'), flatArch2);
run(join(memDir, 'lesson_nested.md'));
out = readFileSync(join(memDir, 'lesson_nested.md'), 'utf8');
check('B: metadata: wrapper line preserved', /^metadata:$/m.test(out), out);
check('B: nested "  type: feedback" child preserved (indentation intact)',
  /^  type: feedback$/m.test(out), out);
check('B: nested "  source: conversation" child preserved',
  /^  source: conversation$/m.test(out), out);
check('B: node_type harness key preserved', /^node_type: memory$/m.test(out), out);
check('B: created inherited', /^created: 2026-03-03$/m.test(out), out);
check('B: recall_count inherited', /^recall_count: 7$/m.test(out), out);
check('B: last_reviewed stamped', new RegExp(`^last_reviewed: ${today}$`, 'm').test(out), out);
check('B: body intact', out.includes('Nested body.'), out);

// --- case C: malformed new file — untouched, archive kept -----------------
const malformed = 'no frontmatter at all\n';
writeFileSync(join(memDir, 'lesson_raw.md'), malformed);
writeFileSync(join(archDir, 'lesson_raw.md'), flatArch);
run(join(memDir, 'lesson_raw.md'));
check('C: malformed new file untouched',
  readFileSync(join(memDir, 'lesson_raw.md'), 'utf8') === malformed, 'was rewritten');
check('C: archive kept for human inspection', existsSync(join(archDir, 'lesson_raw.md')),
  'archive deleted despite no merge');

// --- case D: archive lacking created/recall_count — only last_reviewed ----
const bareArch = `---
name: lesson_bare
description: bare
type: feedback
---

Old.
`;
writeFileSync(join(memDir, 'lesson_bare.md'), flatNew.replace(/lesson_x/g, 'lesson_bare'));
writeFileSync(join(archDir, 'lesson_bare.md'), bareArch);
run(join(memDir, 'lesson_bare.md'));
out = readFileSync(join(memDir, 'lesson_bare.md'), 'utf8');
check('D: no bogus created invented', !/^created:/m.test(out), out);
check('D: no bogus recall_count invented', !/^recall_count:/m.test(out), out);
check('D: last_reviewed still stamped', new RegExp(`^last_reviewed: ${today}$`, 'm').test(out), out);

console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
console.log(`${fail} FAILED`); process.exit(1);
