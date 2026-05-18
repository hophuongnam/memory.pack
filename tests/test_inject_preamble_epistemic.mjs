// TDD: the UserPromptSubmit memory-hint preamble must carry an EPISTEMIC
// warning, not just a RELEVANCE gate.
//
// memory-search-inject.sh prepends a `## Memory hits` block. Its preamble
// said only "These are hints — read them only if they actually inform the
// task" — that gates whether to LOOK at a hit, not whether its content is
// still TRUE. The Read path already gets a harness veracity reminder
// ("Memories are point-in-time observations, not live state … Verify …
// before asserting as fact"); the inject path had no equivalent. That
// asymmetry let an accurate, well-ranked hint get laundered into an
// asserted fact without verification (2026-05-18 grandk incident; see the
// project memory feedback_injected_hint_is_lead_not_fact.md). This pins
// the fix: the epistemic clause must live INSIDE the injected CONTEXT
// string (not merely in a comment), and the original relevance framing
// must remain (the change is additive, not a replacement).
//
// Structural source-regression idiom (cf. test_sdk_resolve.mjs:77). The
// CONTEXT="…" string is extracted specifically — asserting against the
// whole file would pass if the clause were only in a # comment, which is
// exactly the failure this guards. TDD RED is the mutation check: run
// this before editing the hook and it MUST fail on the missing clause.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, '..', 'hooks', 'memory-search-inject.sh');

let fail = 0;
const ok = (m) => console.log('PASS  ' + m);
const bad = (m, e, g) => { console.log(`FAIL  ${m}\n      exp[${e}] got[${g}]`); fail++; };
const has = (m, hay, needle) =>
  (hay.includes(needle) ? ok(m) : bad(m, `contains "${needle}"`, 'absent'));

const src = readFileSync(SRC, 'utf8');

// Extract the injected context string only. The preamble contains no
// double-quote until the closing one ($BODY"), so a non-greedy capture
// from CONTEXT=" to the next " is exactly the injected artifact.
const m = src.match(/CONTEXT="([\s\S]*?)"/);
if (!m) {
  bad('CONTEXT="…" assignment present', 'found', 'not found');
} else {
  const ctx = m[1];

  // Epistemic clause must be IN the injected string, mood-matched to the
  // Read-path harness reminder.
  has('preamble: "unverified" qualifier present', ctx, 'unverified');
  has('preamble: "not live state" (mirrors Read-path mood)', ctx, 'not live state');
  has('preamble: "verify before asserting" instruction present', ctx, 'verify before asserting');
  has('preamble: "as fact" (the assertion the clause guards)', ctx, 'as fact');

  // Additive, not a replacement: the original relevance gate must remain.
  has('preamble: original relevance gate retained', ctx,
      'read them only if they actually inform the task');
}

console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
else { console.log(fail + ' FAILED'); process.exit(1); }
