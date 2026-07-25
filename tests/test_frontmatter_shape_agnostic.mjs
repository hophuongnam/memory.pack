// TDD: the flat-frontmatter rule is RETIRED (2026-07-10).
//
// Both real parsers already resolve recognized keys at ANY indentation
// (_lib.mjs fmParse via /^\s*(key):/, index-memories.py via k.strip()), and the
// CC harness's Write tool nests every memory it creates under a `metadata:`
// wrapper. A census of all 20 stores on 2026-07-10 found 639 of 1517 memories
// (42%) nested. `grep '^type:'` saw 884 files; `grep -E '^[[:space:]]*type:'`
// saw 1515. The flat rule never protected anything — no hook, indexer, or skill
// ever read frontmatter with a column-0 anchor — it only made a human's ad-hoc
// grep feel safe while it silently under-counted 42% of the corpus.
//
// This suite pins the decision two ways:
//
//  (1) STRUCTURAL source-regression (the test_sdk_resolve.mjs:62 idiom): no code
//      line in hooks/, index/, or skills/ may anchor a recognized frontmatter key
//      at column 0. Such a read silently misses every nested memory — the
//      silent-amnesia class again, this time as an under-count rather than a
//      dropped key. A line may opt out with the marker `shape-agnostic-ok`.
//
//  (2) MUTATION check: the scanner is run against a known-bad and a known-good
//      fixture, so it cannot pass vacuously. A surviving mutation means THIS
//      TEST is broken (see feedback_negative_assertion_needs_invariant_marker).
//
//  (3) DOC regression: SCHEMA.md must not re-grow the retired instruction, and
//      must keep documenting the tolerant grep idiom. Without this the prose
//      quietly reverts and the next agent reintroduces the dance.
//
// Effectiveness of the tolerant read path itself is pinned elsewhere, against
// the real parsers and real fixtures: tests/test_recall_frontmatter_preserve.mjs.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');

let fail = 0;
const ok = (m) => console.log('PASS  ' + m);
const bad = (m, e, g) => { console.log(`FAIL  ${m}\n      exp[${e}] got[${g}]`); fail++; };

const KEYS = ['name', 'description', 'type', 'originSessionId', 'node_type',
              'created', 'last_recalled', 'recall_count', 'last_reviewed'];

// A `^` immediately followed by a recognized key (through an optional quote or
// regex delimiter) is column-0 anchored. The tolerant forms `^\s*type:` and
// `^[[:space:]]*type:` interpose a whitespace class and must NOT match.
const BAD = new RegExp(String.raw`\^(?:${KEYS.join('|')})\s*:`);

const OPT_OUT = 'shape-agnostic-ok';

// Comments are prose, not behaviour: a comment may legitimately quote `^type:`
// while explaining why it is wrong. Markdown is left intact ('#' is a heading).
function codeOnly(text, ext) {
  if (ext === 'md') return text;
  const line = ext === 'mjs' ? /\/\/.*$/ : /#.*$/;   // sh, py
  return text.split('\n').map((l) => l.replace(line, '')).join('\n');
}

function sources() {
  const out = [];
  for (const [dir, exts] of [['hooks', ['sh', 'mjs']], ['index', ['py']]]) {
    const d = join(ROOT, dir);
    if (!existsSync(d)) continue;
    for (const f of readdirSync(d)) {
      const ext = f.split('.').pop();
      if (exts.includes(ext)) out.push([join(d, f), ext]);
    }
  }
  // Skill bodies are executed by an LLM: a `grep '^type:'` in SKILL.md is a
  // real consumer, not documentation.
  const sk = join(ROOT, 'skills');
  if (existsSync(sk)) {
    for (const s of readdirSync(sk)) {
      const p = join(sk, s, 'SKILL.md');
      if (existsSync(p)) out.push([p, 'md']);
    }
  }
  return out;
}

// --- (1) structural: the live tree must be clean ---------------------------
const offenders = [];
for (const [path, ext] of sources()) {
  const text = codeOnly(readFileSync(path, 'utf8'), ext);
  text.split('\n').forEach((l, i) => {
    if (l.includes(OPT_OUT)) return;
    if (BAD.test(l)) offenders.push(`${relative(ROOT, path)}:${i + 1}: ${l.trim()}`);
  });
}
offenders.length === 0
  ? ok('no column-0 frontmatter anchor in hooks/ index/ skills/')
  : bad('no column-0 frontmatter anchor in hooks/ index/ skills/', 'none',
        '\n      ' + offenders.join('\n      '));

// --- (2) mutation: the scanner must actually discriminate -------------------
const MUTANT = `  if grep -q '^type: feedback' "$f"; then`;
BAD.test(MUTANT)
  ? ok('mutation: scanner catches a column-0 read')
  : bad('mutation: scanner catches a column-0 read', 'flagged', 'missed');

for (const tolerant of [
  `grep -qE '^[[:space:]]*type: feedback' "$f"`,
  `line.match(/^\\s*([A-Za-z_][A-Za-z0-9_]*):\\s*(.*)$/)`,
  `k, _, v = line.partition(":"); k = k.strip()`,
]) {
  !BAD.test(tolerant)
    ? ok(`tolerant form not flagged: ${tolerant.slice(0, 34)}…`)
    : bad('tolerant form not flagged', 'clean', 'flagged');
}

// --- (3) doc regression: SCHEMA.md must stay relaxed ------------------------
// Only the NORMATIVE body is checked. The history section below the marker
// exists precisely to quote the instructions it retired; a substring scan
// cannot tell a live rule from an epitaph, so it must not read that far.
const HISTORY = 'History of the nested-shape handling';
const schemaFull = readFileSync(join(ROOT, 'SCHEMA.md'), 'utf8');
const cut = schemaFull.indexOf(HISTORY);
cut > 0
  ? ok('SCHEMA.md: history marker present (bounds the normative body)')
  : bad('SCHEMA.md: history marker present', HISTORY, 'absent');
const schema = cut > 0 ? schemaFull.slice(0, cut) : schemaFull;

for (const retired of [
  'Write the flat form documented here',
  'Write flat for the writes you control',
  'then immediately `Edit` the `metadata:` block',
  'a flat write stays flat',
]) {
  !schema.includes(retired)
    ? ok(`SCHEMA.md normative body: retired instruction absent — ${JSON.stringify(retired.slice(0, 36))}`)
    : bad('SCHEMA.md normative body: retired instruction absent', `no ${JSON.stringify(retired)}`, 'present');
}

// Mutation guard for the slice itself: the epitaph must exist somewhere in the
// file, below the marker. If it did not, the check above would be passing
// because the phrase is simply gone — not because it was correctly quarantined.
schemaFull.includes('a flat write stays flat') && !schema.includes('a flat write stays flat')
  ? ok('SCHEMA.md: retired instruction survives in history, quarantined from body')
  : bad('SCHEMA.md: retired instruction quarantined', 'in history, not in body',
        `full=${schemaFull.includes('a flat write stays flat')} body=${schema.includes('a flat write stays flat')}`);

for (const required of [
  'recognized keys at any indentation',   // the relaxed contract, stated
  '^[[:space:]]*',                        // the correct grep idiom, documented
]) {
  schema.includes(required)
    ? ok(`SCHEMA.md: documents ${JSON.stringify(required)}`)
    : bad('SCHEMA.md: documents the relaxed contract', required, 'absent');
}

console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
else { console.log(fail + ' FAILED'); process.exit(1); }
