// TDD: the archive→active auto-promotion path in update-recall.mjs.
//
// A Read landing on `<store>/memory/archive/<file>.md` that bumps
// recall_count past MEMORY_PROMOTION_THRESHOLD must atomically move the
// file back to the ACTIVE memory root, insert a MEMORY.md pointer line in
// the type-appropriate section, move the per-session recall marker, and
// append an audit line to `.archive-promote.log`. This path had ZERO test
// coverage (grep promote tests/ → comments only) — every regression in it
// is the silent-amnesia class: an archived memory that earned its way back
// simply never returns.
//
// Behavioral-subprocess idiom (test_recall_frontmatter_preserve.mjs): run
// the REAL update-recall.mjs against a sandboxed store. MEMORY_PACK_HOME +
// MEMORY_SEARCH_DB point into the sandbox so the backgrounded indexer
// re-sync can never touch the live search.db.
//
// RED (three known bugs):
//   * MEMORY_PROMOTION_THRESHOLD=garbage → parseInt NaN → `count >= NaN`
//     is false forever → promotion silently OFF (no Number.isFinite guard).
//   * nested archive/sub/x.md → activePath replace() mispathed to
//     memory/sub/x.md (ENOENT) and the error log mispathed into archive/sub.
//   * (kept-working pins: flat promote, collision-skip, below-threshold.)

import { execFileSync } from 'node:child_process';
import {
  mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const RECALL = join(HERE, '..', 'hooks', 'update-recall.mjs');

let fail = 0;
const ok = (m) => console.log('PASS  ' + m);
const bad = (m, e, g) => { console.log(`FAIL  ${m}\n      exp[${e}] got[${g}]`); fail++; };
const eq = (m, e, g) => (e === g ? ok(m) : bad(m, e, g));
const has = (m, hay, needle) =>
  hay.includes(needle) ? ok(m) : bad(m, `contains ${JSON.stringify(needle)}`, 'absent');
// Missing file → '' so a mispathed log reads as a clean FAIL, not a crash
// that aborts the remaining cases.
const readOr = (p) => (existsSync(p) ? readFileSync(p, 'utf8') : '');

const today = new Date().toISOString().slice(0, 10);
const tmp = mkdtempSync(join(tmpdir(), 'mp-promote-'));

const FM = (name, desc, type, count) =>
  `---\nname: ${name}\ndescription: ${desc}\ntype: ${type}\ncreated: 2026-01-01\nrecall_count: ${count}\n---\nbody\n`;

// A store mimicking ~/.claude/projects/<slug>/memory — the path must
// contain `/memory/archive/` for the hook's isArchived gate.
function mkStore(label) {
  const mem = join(tmp, label, 'memory');
  mkdirSync(join(mem, 'archive'), { recursive: true });
  writeFileSync(join(mem, 'MEMORY.md'), [
    '# Memory Index',
    '',
    '## User & feedback',
    '- 2026-01-01 [seed.md](seed.md) — seed',
    '',
    '## Projects',
    '',
    '## Infrastructure & reference',
    '',
  ].join('\n'));
  return mem;
}

function run(path, sid, extraEnv = {}) {
  const env = {
    ...process.env,
    MEMORY_PACK_HOME: tmp,
    MEMORY_SEARCH_DB: join(tmp, 'search.db'),
  };
  delete env.MEMORY_PROMOTION_THRESHOLD;
  Object.assign(env, extraEnv);
  execFileSync('node', [RECALL, path, sid], { encoding: 'utf8', env });
}

// === flat promote: move + MEMORY.md insert + marker move + audit line ===
{
  const mem = mkStore('s1');
  const arch = join(mem, 'archive', 'promo.md');
  writeFileSync(arch, FM('promo', 'promoted desc', 'feedback', 2));
  run(arch, 'sid-a');

  const active = join(mem, 'promo.md');
  eq('promote: file moved to active root', true, existsSync(active));
  eq('promote: archive copy gone', false, existsSync(arch));
  has('promote: recall_count bumped to 3 in promoted file',
      readFileSync(active, 'utf8'), 'recall_count: 3');

  const idx = readFileSync(join(mem, 'MEMORY.md'), 'utf8');
  has('promote: MEMORY.md gains pointer line', idx,
      `- ${today} [promo.md](promo.md) — promoted desc`);
  const at = idx.indexOf('[promo.md]');
  (at > idx.indexOf('## User & feedback') && at < idx.indexOf('## Projects'))
    ? ok('promote: entry lands in the type section')
    : bad('promote: entry lands in the type section',
          'between "## User & feedback" and "## Projects"', `index ${at}`);

  eq('promote: session marker moved to active dir', true,
     existsSync(join(mem, '.recalled-sid-a-promo.touched')));
  eq('promote: no marker left in archive dir', false,
     existsSync(join(mem, 'archive', '.recalled-sid-a-promo.touched')));
  has('promote: audit log line at memory root',
      readOr(join(mem, '.archive-promote.log')),
      ' promote promo.md (recall_count=3');
}

// === collision: active file of the same name exists → skip, log, bump ===
{
  const mem = mkStore('s2');
  const arch = join(mem, 'archive', 'promo.md');
  writeFileSync(arch, FM('promo', 'd', 'feedback', 2));
  writeFileSync(join(mem, 'promo.md'), FM('promo', 'd', 'feedback', 0));
  run(arch, 'sid-b');

  eq('collision: archive copy stays put', true, existsSync(arch));
  has('collision: recall bump still applied to archive copy',
      readFileSync(arch, 'utf8'), 'recall_count: 3');
  has('collision: skip logged',
      readOr(join(mem, '.archive-promote.log')),
      'skip-collision promo.md');
}

// === garbage MEMORY_PROMOTION_THRESHOLD: fall back to default 3 =========
// RED: parseInt('not-a-number') → NaN → `newCount >= NaN` false forever —
// promotion silently OFF with no error anywhere.
{
  const mem = mkStore('s3');
  const arch = join(mem, 'archive', 'promo.md');
  writeFileSync(arch, FM('promo', 'd', 'feedback', 2));
  run(arch, 'sid-c', { MEMORY_PROMOTION_THRESHOLD: 'not-a-number' });

  eq('NaN threshold: falls back to 3 and still promotes', true,
     existsSync(join(mem, 'promo.md')));
}

// === nested archive/sub/: promote to memory ROOT by basename ============
// RED: activePath was derived by replace('/memory/archive/','/memory/') →
// memory/sub/nested.md (ENOENT, dir doesn't exist) and the error log
// mispathed to archive/sub/.archive-promote.log.
{
  const mem = mkStore('s4');
  mkdirSync(join(mem, 'archive', 'sub'), { recursive: true });
  const arch = join(mem, 'archive', 'sub', 'nested.md');
  writeFileSync(arch, FM('nested', 'nested desc', 'reference', 2));
  run(arch, 'sid-d');

  eq('nested archive: promotes to memory ROOT by basename', true,
     existsSync(join(mem, 'nested.md')));
  eq('nested archive: no mispath into memory/sub/', false,
     existsSync(join(mem, 'sub', 'nested.md')));
  has('nested archive: audit log at memory root',
      readOr(join(mem, '.archive-promote.log')),
      ' promote nested.md (recall_count=3');
  eq('nested archive: no stray log inside archive/sub', false,
     existsSync(join(mem, 'archive', 'sub', '.archive-promote.log')));
  const idx = readFileSync(join(mem, 'MEMORY.md'), 'utf8');
  const at = idx.indexOf('[nested.md]');
  (at > idx.indexOf('## Infrastructure & reference'))
    ? ok('nested archive: reference type lands in reference section')
    : bad('nested archive: reference type lands in reference section',
          'after "## Infrastructure & reference"', `index ${at}`);
}

// === below threshold: nothing moves, nothing logged =====================
// Mutation guard: a promotion path that fires unconditionally would pass
// every case above — this pins the gate itself.
{
  const mem = mkStore('s5');
  const arch = join(mem, 'archive', 'promo.md');
  writeFileSync(arch, FM('promo', 'd', 'feedback', 1));
  run(arch, 'sid-e');

  eq('below threshold: stays archived at count 2', true, existsSync(arch));
  eq('below threshold: not promoted', false, existsSync(join(mem, 'promo.md')));
  eq('below threshold: no audit log written', false,
     existsSync(join(mem, '.archive-promote.log')));
}

rmSync(tmp, { recursive: true, force: true });
console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
else { console.log(fail + ' FAILED'); process.exit(1); }
