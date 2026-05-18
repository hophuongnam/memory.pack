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
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

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

rmSync(tmp, { recursive: true, force: true });
console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
else { console.log(fail + ' FAILED'); process.exit(1); }
