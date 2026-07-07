// TDD: the recall hook must NEVER restructure frontmatter.
//
// Silent-amnesia class: update-recall.mjs (PostToolUse on Read) bumps
// recall_count/last_recalled. Historically it REBUILT the whole frontmatter
// block from a parsed key map, which flattened the stock system-prompt's
// nested `metadata: { type }` shape and could drop indented keys. The agreed
// design ("go with the flow") is: tolerate every shape on READ, mutate ONLY
// the two counter lines, and never reshape the file. CC's own output is not
// uniform (intermittent `node_type:` injection), so reshaping is a fight we
// stop fighting — effectiveness is guaranteed by tolerant readers + this test,
// not by forcing a canonical on-disk shape.
//
// This test runs the REAL update-recall.mjs against flat / nested /
// node_type fixtures and asserts: (1) shape byte-preserved except the two
// counter lines, (2) counters bumped, (3) body intact, (4) the REAL Python
// indexer parser still extracts `type` from the result. RED until the
// flatten-rebuild is removed.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { fmParse, fmSetInPlace, fmSerialize } from '../hooks/_lib.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const RECALL = join(HERE, '..', 'hooks', 'update-recall.mjs');
const INDEXER = join(HERE, '..', 'index', 'index-memories.py');

let fail = 0;
const ok = (m) => console.log('PASS  ' + m);
const bad = (m, e, g) => { console.log(`FAIL  ${m}\n      exp[${e}] got[${g}]`); fail++; };
const eq = (m, e, g) => (e === g ? ok(m) : bad(m, e, g));
const has = (m, hay, needle) =>
  hay.includes(needle) ? ok(m) : bad(m, `contains ${JSON.stringify(needle)}`, 'absent');

const today = new Date().toISOString().slice(0, 10);
const tmp = mkdtempSync(join(tmpdir(), 'mp-recall-'));

// Real Python indexer parser, loaded by importlib (filename has a hyphen).
// This is the actual code path index-memories.py uses — not a copy.
const PYLOAD = join(tmp, 'loadtype.py');
writeFileSync(PYLOAD, `import importlib.util, sys
spec = importlib.util.spec_from_file_location("idx", ${JSON.stringify(INDEXER)})
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fm, _ = m.parse_frontmatter(open(sys.argv[1]).read())
print(fm.get("type", ""))
`);
const indexerType = (p) =>
  execFileSync('python3', [PYLOAD, p], { encoding: 'utf8' }).trim();

function runRecall(name, fm, expectedType, shapeChecks) {
  const path = join(tmp, name);
  const body = `---\n${fm}\n---\nbody line one\nbody line two\n`;
  writeFileSync(path, body);
  execFileSync('node', [RECALL, path, `sid-${name}`], { encoding: 'utf8' });
  const out = readFileSync(path, 'utf8');

  // (2) counters bumped
  has(`${name}: recall_count bumped to 1`, out, '\nrecall_count: 1');
  has(`${name}: last_recalled stamped today`, out, `\nlast_recalled: ${today}`);
  // (3) body intact, frontmatter terminator intact
  has(`${name}: body preserved`, out, '\n---\nbody line one\nbody line two\n');
  // (1) shape preserved (per-fixture literal checks)
  for (const [label, needle] of shapeChecks) has(`${name}: ${label}`, out, needle);
  // (4) effectiveness: real Python indexer still resolves `type`
  eq(`${name}: index-memories.py resolves type`, expectedType, indexerType(path));
}

// --- flat (canonical) : must stay flat, counters appended at col 0 ---
runRecall('flat.md',
  'name: flat-mem\ndescription: d\ntype: feedback\ncreated: 2026-05-18',
  'feedback',
  [['type stays column-0', '\ntype: feedback\n']]);

// --- nested (stock system-prompt shape) : wrapper + indent PRESERVED ---
runRecall('nested.md',
  'name: nested-mem\ndescription: d\nmetadata:\n  type: project\n  created: 2026-05-18',
  'project',
  [['metadata: wrapper kept', '\nmetadata:\n'],
   ['type stays indented',    '\n  type: project\n']]);

// --- node_type (CC harness injection, nested) : node_type SURVIVES ---
runRecall('nodetype.md',
  'name: nt-mem\ndescription: d\nmetadata:\n  node_type: memory\n  type: reference\n  originSessionId: abc',
  'reference',
  [['metadata: wrapper kept',     '\nmetadata:\n'],
   ['node_type survives indented', '\n  node_type: memory\n'],
   ['type stays indented',         '\n  type: reference\n']]);

// --- mutation check: prove the detector is not vacuously true ---
// A flattened nested block must FAIL the "indent preserved" needle, else the
// shape assertions above could pass for the wrong reason.
const flattened = '---\nname: x\nmetadata:\ntype: project\n---\nbody\n';
(!flattened.includes('\n  type: project\n'))
  ? ok('mutation check: flattened block correctly fails indent needle')
  : bad('mutation check: detector not vacuous', 'flattened detected', 'missed');

// === Re-read must NOT rewrite the file (the Edit "modified since read" race) ===
// A second Read in the SAME session is byte-identical (recall_count already
// bumped, last_recalled already today). The hook must SKIP the write — a
// tmp+rename changes the inode/ctime and busts the Edit tool's post-read
// freshness check (see feedback_memory_edit_recall_race.md). RED until
// update-recall.mjs short-circuits on `out === body`.
{
  const path = join(tmp, 'reread.md');
  writeFileSync(path, '---\nname: rr\ndescription: d\ntype: feedback\ncreated: 2026-05-18\n---\nbody\n');
  const sid = 'sid-reread';
  execFileSync('node', [RECALL, path, sid], { encoding: 'utf8' }); // 1st read: bumps + writes
  const afterFirst = readFileSync(path, 'utf8');
  const inoFirst = statSync(path).ino;
  execFileSync('node', [RECALL, path, sid], { encoding: 'utf8' }); // 2nd read: must be a no-op
  eq('re-read: content byte-identical', afterFirst, readFileSync(path, 'utf8'));
  eq('re-read: inode unchanged (file not rewritten)', inoFirst, statSync(path).ino);
}

// === _lib.mjs frontmatter-helper unit contract (memory-file integrity) ===
// fmParse must tolerate empty frontmatter and CRLF fences; duplicate keys
// must be read AND written at the LAST occurrence; parse→serialize must be
// a byte-identical round-trip on every tolerated shape. RED until _lib.mjs
// searches the close fence from index 3, learns `eol`, and fmSetInPlace
// rewrites the last match.
{
  // Empty frontmatter `---\n---\n` + a later body hr: the close fence is
  // the IMMEDIATE one, not the body hr (the body-splice bug: indexOf
  // started at 4 and skipped the adjacent close).
  const emptyFm = '---\n---\nSome note.\n\n---\n\nMore.\n';
  const p = fmParse(emptyFm);
  if (!p) bad('unit: empty frontmatter parses', 'object', 'null');
  else {
    eq('unit: empty frontmatter → zero fm lines', 0, p.lines.length);
    eq('unit: empty frontmatter → body starts after immediate fence',
       'Some note.\n\n---\n\nMore.\n', p.rest);
    eq('unit: empty frontmatter round-trips byte-stable',
       emptyFm, fmSerialize(p.lines, p.rest, p.eol));
  }

  // CRLF fences: parse must not return null; lines stay verbatim (\r kept);
  // VALUE reads are \r-stripped; round-trip byte-identical.
  const crlf = '---\r\nname: x\r\ntype: feedback\r\n---\r\nbody\r\n';
  const c = fmParse(crlf);
  if (!c) bad('unit: CRLF frontmatter parses', 'object', 'null');
  else {
    eq('unit: CRLF value read is \\r-stripped', 'feedback', c.keys.get('type'));
    eq('unit: CRLF lines stay verbatim', 'name: x\r', c.lines[0]);
    eq('unit: CRLF round-trips byte-stable', crlf, fmSerialize(c.lines, c.rest, c.eol));
  }

  // CRLF + empty frontmatter combined.
  const crlfEmpty = '---\r\n---\r\nB\r\n';
  const ce = fmParse(crlfEmpty);
  if (!ce) bad('unit: CRLF empty frontmatter parses', 'object', 'null');
  else eq('unit: CRLF empty frontmatter round-trips byte-stable',
          crlfEmpty, fmSerialize(ce.lines, ce.rest, ce.eol));

  // LF default: the old two-arg fmSerialize call shape must keep working.
  const lf = '---\nk: v\n---\nb\n';
  const l = fmParse(lf);
  eq('unit: LF round-trip with eol omitted stays byte-stable',
     lf, fmSerialize(l.lines, l.rest));

  // Duplicate key: read takes the LAST occurrence (long-standing) and
  // fmSetInPlace must WRITE the last occurrence too, else the counter
  // freezes (read 7 → write first line → read 7 again forever).
  const d = fmParse('---\na: 1\na: 2\n---\n');
  eq('unit: dup-key read takes last occurrence', '2', d.keys.get('a'));
  fmSetInPlace(d.lines, 'a', '9');
  eq('unit: dup-key write leaves first occurrence verbatim', 'a: 1', d.lines[0]);
  eq('unit: dup-key write rewrites the LAST occurrence', 'a: 9', d.lines[1]);

  // fmSetInPlace on a CRLF line preserves the trailing \r.
  const crLines = ['recall_count: 1\r'];
  fmSetInPlace(crLines, 'recall_count', '2');
  eq('unit: fmSetInPlace preserves trailing \\r', 'recall_count: 2\r', crLines[0]);
}

// === empty-frontmatter file: counters must land IN frontmatter, not body ===
// RED: fmParse treated the body hr as the close fence, so the recall
// counters got SPLICED INTO THE BODY between "Some note." and the hr.
{
  const path = join(tmp, 'emptyfm.md');
  writeFileSync(path, '---\n---\nSome note.\n\n---\n\nMore.\n');
  execFileSync('node', [RECALL, path, 'sid-emptyfm'], { encoding: 'utf8' });
  eq('emptyfm: counters in frontmatter, body byte-preserved',
     `---\nrecall_count: 1\nlast_recalled: ${today}\n---\nSome note.\n\n---\n\nMore.\n`,
     readFileSync(path, 'utf8'));
}

// === CRLF file: hook must bump (not silently no-op) and preserve CRLF ===
// RED: fmParse returned null on `---\r\n` → recall tracking silently dead
// for any CRLF memory file (appended counter lines are LF; that's fine —
// existing bytes are what must never reshape).
{
  const path = join(tmp, 'crlf.md');
  writeFileSync(path, '---\r\nname: crlf\r\ntype: feedback\r\n---\r\nbody one\r\nbody two\r\n');
  execFileSync('node', [RECALL, path, 'sid-crlf'], { encoding: 'utf8' });
  eq('crlf: counters bumped, fences + lines + body stay CRLF-verbatim',
     `---\r\nname: crlf\r\ntype: feedback\r\nrecall_count: 1\nlast_recalled: ${today}\n---\r\nbody one\r\nbody two\r\n`,
     readFileSync(path, 'utf8'));
}

// === duplicate recall_count: counter must PROGRESS across sessions ===
// RED: read took the LAST occurrence but the write went to the FIRST →
// the live (last) line never changed → count frozen at its old value.
{
  const path = join(tmp, 'dup.md');
  writeFileSync(path, '---\nname: dup\nrecall_count: 4\ntype: feedback\nrecall_count: 7\n---\nbody\n');
  execFileSync('node', [RECALL, path, 'sid-dup1'], { encoding: 'utf8' });
  execFileSync('node', [RECALL, path, 'sid-dup2'], { encoding: 'utf8' });
  const out = readFileSync(path, 'utf8');
  has('dup: first occurrence left verbatim', out, '\nrecall_count: 4\n');
  has('dup: last occurrence progressed 7→8→9', out, '\nrecall_count: 9\n');
  (!out.includes('recall_count: 8'))
    ? ok('dup: no frozen intermediate value')
    : bad('dup: no frozen intermediate value', 'no recall_count: 8', 'found one');
}

// === structural: atomic-write tmp must be pid-unique + failure-cleaned ===
// Two concurrent Reads of the same memory (two sessions) share a fixed
// `.recall.tmp` name: the loser's renameSync throws ENOENT, the hook dies
// before writing its session marker → that session's NEXT Read double-bumps
// recall_count. Pin the pid-suffixed tmp and the unlink-on-fail cleanup
// (mirrors archive-resurrect.mjs's write idiom).
{
  const src = readFileSync(RECALL, 'utf8');
  has('recall src: tmp name is pid-suffixed', src, '.recall.tmp.${process.pid}');
  has('recall src: failed write unlinks its tmp', src, 'unlinkSync(tmp)');
  /try\s*\{\s*writeFileSync\(tmp, out\)/.test(src)
    ? ok('recall src: write+rename wrapped in try/catch')
    : bad('recall src: write+rename wrapped in try/catch',
          'try { writeFileSync(tmp, out)', 'absent');
}

rmSync(tmp, { recursive: true, force: true });
console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
else { console.log(fail + ' FAILED'); process.exit(1); }
