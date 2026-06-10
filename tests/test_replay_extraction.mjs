// TDD: replay.mjs transcript extraction — the text fed to the replay/
// promotion agents must reflect what the human and assistant actually said.
//
// Bugs being pinned (verified against real CC transcripts 2026-06-10):
//   1. isMeta:true user entries with STRING content (our own auto-save-stop
//      feedback, CC "Caveat:" bookkeeping) passed the old
//      `typeof content === 'string'` check and were fed to the agents as
//      fake "USER:" lines — the exact lesson log-token-rate.sh already
//      mutation-pins (reference_cc_transcript_isMeta_mid_turn.md).
//   2. Array-form user prompts (image pastes today; any future CC format
//      shift) were silently dropped — replay would go blind on the user
//      side with no error. Array entries carrying tool_result blocks are
//      continuations and must stay excluded. The isMeta filter must run
//      FIRST: skill-injection isMeta entries are huge array-text blobs.
//   3. No size cap: a long session blew the prompt past the model context
//      → API error → exit 3 → "Replay failed" synthetic banner. The
//      longest (most valuable) sessions were the most likely to lose their
//      summary. truncateConversation keeps head + tail around an elision
//      marker.
//
// Pure functions in _lib.mjs (extractConversation, truncateConversation)
// so they are testable without the agent SDK; a structural layer asserts
// replay.mjs actually consumes them.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(HERE, '..', 'hooks', '_lib.mjs');

const { extractConversation, truncateConversation } = await import(LIB);

let fail = 0;
const ok = (m) => console.log('PASS  ' + m);
const bad = (m, d) => { console.log(`FAIL  ${m}\n      ${d}`); fail++; };
const check = (m, cond, d) => (cond ? ok(m) : bad(m, d));

check('extractConversation exported', typeof extractConversation === 'function',
  `got ${typeof extractConversation}`);
check('truncateConversation exported', typeof truncateConversation === 'function',
  `got ${typeof truncateConversation}`);
if (typeof extractConversation !== 'function' || typeof truncateConversation !== 'function') {
  console.log('----'); console.log(`${fail} FAILED`); process.exit(1);
}

// ─── extraction semantics ──────────────────────────────────────────────
const msgs = [
  { type: 'user', message: { role: 'user', content: 'real prompt one' } },
  { type: 'assistant', message: { role: 'assistant', content: [
    { type: 'thinking', thinking: 'hidden' },
    { type: 'text', text: 'assistant answer one' },
    { type: 'text', text: 'second block ignored' },
  ] } },
  // tool_result continuation — NOT a user turn
  { type: 'user', message: { role: 'user', content: [
    { type: 'tool_result', tool_use_id: 't1', content: 'raw tool output' },
  ] } },
  // isMeta STRING — our auto-save feedback; must be excluded
  { type: 'user', isMeta: true, message: { role: 'user', content:
    'Stop hook feedback: AUTO-SAVE checkpoint reached (50 exchanges).' } },
  // isMeta ARRAY-text — skill injection blob; must be excluded
  { type: 'user', isMeta: true, message: { role: 'user', content: [
    { type: 'text', text: 'Base directory for this skill: /huge/skill/blob' },
  ] } },
  // array-form REAL user prompt (no tool_result) — must be included
  { type: 'user', message: { role: 'user', content: [
    { type: 'text', text: 'array prompt' },
    { type: 'text', text: 'second line' },
  ] } },
  // assistant with no text block (pure tool_use) — contributes nothing
  { type: 'assistant', message: { role: 'assistant', content: [
    { type: 'tool_use', id: 't2', name: 'X', input: {} },
  ] } },
  // mixed array with a tool_result → continuation, excluded
  { type: 'user', message: { role: 'user', content: [
    { type: 'tool_result', tool_use_id: 't2', content: 'r' },
    { type: 'text', text: 'trailing note' },
  ] } },
];

const text = extractConversation(msgs);

check('string user prompt included', text.includes('USER: real prompt one'), text);
check('assistant first text block included', text.includes('ASSISTANT: assistant answer one'), text);
check('assistant later text blocks not duplicated', !text.includes('second block ignored'), text);
check('tool_result continuation excluded', !text.includes('raw tool output'), text);
check('isMeta string entry excluded', !text.includes('AUTO-SAVE checkpoint'), text);
check('isMeta array-text entry excluded (skill blob)', !text.includes('skill blob'), text);
check('array-form real prompt included', text.includes('USER: array prompt'), text);
check('array-form prompt joins its text blocks', /USER: array prompt\s+second line/.test(text), text);
check('mixed tool_result+text array excluded', !text.includes('trailing note'), text);

check('empty input → empty string', extractConversation([]) === '', `got [${extractConversation([])}]`);
check('null-safe on malformed entries',
  extractConversation([{ type: 'user' }, { type: 'assistant', message: {} }]) === '',
  'threw or returned non-empty');

// ─── truncation semantics ──────────────────────────────────────────────
const short = 'short transcript';
check('under cap → unchanged', truncateConversation(short, { head: 100, tail: 100 }) === short,
  truncateConversation(short, { head: 100, tail: 100 }));

const long = 'H'.repeat(500) + 'M'.repeat(5000) + 'T'.repeat(500);
const cut = truncateConversation(long, { head: 200, tail: 300 });
check('over cap → head preserved', cut.startsWith('H'.repeat(200)), cut.slice(0, 50));
check('over cap → tail preserved', cut.endsWith('T'.repeat(300)), cut.slice(-50));
check('over cap → elision marker present', /elided/.test(cut), cut.slice(150, 350));
check('over cap → bounded size', cut.length < 200 + 300 + 120, `len=${cut.length}`);
// elided = 6000 total − 200 head − 300 tail = 5500
check('marker reports elided char count', /5500/.test(cut.match(/\[\.\.\..*?\]/)?.[0] ?? cut),
  cut.slice(180, 320));

// default caps must exist and be generous-but-finite
const big = 'x'.repeat(2_000_000);
const defCut = truncateConversation(big);
check('default caps bound a 2M-char transcript', defCut.length < 600_000, `len=${defCut.length}`);
check('default caps leave small transcripts alone', truncateConversation('abc') === 'abc',
  truncateConversation('abc'));

// ─── structural: replay.mjs consumes the shared helpers ───────────────
const replaySrc = readFileSync(join(HERE, '..', 'hooks', 'replay.mjs'), 'utf8')
  .split('\n').filter((l) => !/^\s*\/\//.test(l)).join('\n');
check('replay.mjs imports/uses extractConversation', /extractConversation/.test(replaySrc),
  'rewire replay.mjs to the shared extraction');
check('replay.mjs imports/uses truncateConversation', /truncateConversation/.test(replaySrc),
  'rewire replay.mjs to the shared truncation');
check('replay.mjs no longer string-only on user content',
  !/typeof m\.message\?\.content === 'string'/.test(replaySrc),
  'old string-only check still present');

console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
console.log(`${fail} FAILED`); process.exit(1);
