// TDD: the PENDING_MEMORIES.md header template must carry an EPISTEMIC
// warning about confabulation, not just a review-mechanics protocol.
//
// replay.mjs pass 2 appends proposals from a DETACHED agent that sees the
// transcript + carry-forward context but no memory bodies and no live
// systems. The header's review protocol said only "compare against existing
// memory files" — a DUPLICATE gate, not a TRUTH gate. That let a proposal's
// invented specifics be merged as fact: on 2026-06-11 a replay proposal
// claimed a 5/5 smoke result (user reported 4/5), a team-channel behavior,
// and an "ordering bug" seen by a user (duy.nguyen) who exists in no
// transcript and no live system — the agent narrated a carried-forward
// TODO's expected completion as observed fact (see Rikkei-HelpDesk store,
// feedback_verify_replay_memory_proposals.md). This is the review-side
// sibling of test_inject_preamble_epistemic.mjs: every path that hands a
// future session machine-generated "facts" must label them unverified and
// demand ground-truth checks.
//
// Structural source-regression idiom (cf. test_sdk_resolve.mjs:62). The
// `const header = \`…\`` template literal is extracted specifically —
// asserting against the whole file would pass if the clauses were only in
// a // comment or in the promotion PROMPT, which is exactly the failure
// this guards (the prompt talks to the proposing agent; the header talks
// to the reviewing session). TDD RED is the mutation check: run this
// before editing replay.mjs and it MUST fail on the missing clauses.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, '..', 'hooks', 'replay.mjs');

let fail = 0;
const ok = (m) => console.log('PASS  ' + m);
const bad = (m, e, g) => { console.log(`FAIL  ${m}\n      exp[${e}] got[${g}]`); fail++; };
const has = (m, hay, needle) =>
  (hay.includes(needle) ? ok(m) : bad(m, `contains "${needle}"`, 'absent'));

const src = readFileSync(SRC, 'utf8');

// Extract the header template literal only. Escaped \` backticks inside it
// never start a line, so the first newline+`; terminates exactly the
// template assignment.
const m = src.match(/const header = `([\s\S]*?)\n`;/);
if (!m) {
  bad('const header = `…` template present in replay.mjs', 'found', 'not found');
} else {
  const hdr = m[1];

  // Epistemic clauses must be IN the header artifact future sessions read.
  has('header: "unverified claims, not observations" framing present', hdr,
      'unverified claims, not observations');
  has('header: names confabulation as the failure mode', hdr, 'confabulate');
  has('header: ground-truth check against transcripts', hdr, 'transcripts');
  has('header: ground-truth check against live systems', hdr, 'live systems');
  has('header: the carried-forward-TODO tell is documented', hdr,
      'carried-forward TODO');

  // The verification step must gate the Create/Merge choice — verifying
  // AFTER merging is the read-side incident all over again.
  const verifyAt = hdr.indexOf('Verify every specific');
  const chooseAt = hdr.indexOf('choose ONE');
  if (verifyAt === -1) {
    bad('header: "Verify every specific" protocol step present',
        'found', 'absent');
  } else if (chooseAt === -1) {
    bad('header: "choose ONE" step still present', 'found', 'absent');
  } else if (verifyAt < chooseAt) {
    ok('header: verification step precedes the Create/Merge choice');
  } else {
    bad('header: verification step precedes the Create/Merge choice',
        `index ${verifyAt} < ${chooseAt}`, 'verify step after choose step');
  }

  // Additive, not a replacement: the original mechanics must remain.
  has('header: detached-agent rationale retained', hdr,
      'could not commit directly');
  has('header: duplicate-comparison step retained', hdr,
      'the actual files, not just the index');
  has('header: terminal cleanup step retained', hdr,
      'Delete this file entirely once no proposals remain.');
}

console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
else { console.log(fail + ' FAILED'); process.exit(1); }
