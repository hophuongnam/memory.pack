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

const { extractConversation, truncateConversation, isUsageLimitSignal } = await import(LIB);

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

// ─── structural: both passes ride the 'sonnet' alias, never a pinned ID ──
// The SDK resolves the bare alias to the current latest Sonnet (verified
// behaviorally against the real SDK: 'sonnet' → claude-sonnet-4-6 on
// @anthropic-ai/claude-agent-sdk 0.2.77). A pinned ID silently freezes the
// replay agent on a stale model at every future Sonnet release.
const aliasHits = (replaySrc.match(/model:\s*'sonnet'/g) || []).length;
check('both replay passes use the sonnet alias', aliasHits === 2, `found ${aliasHits}, want 2`);
check('no pinned claude-sonnet-* model ID in code', !/claude-sonnet-/.test(replaySrc),
  'pinned Sonnet ID present — use the bare alias');

// ─── isUsageLimitSignal: benign outage vs real failure ──────────────────
// replay.mjs exits 2 (benign → session-end carries the prior boot context
// forward) on a usage-window outage and 3 (loud synthetic banner) on a real
// crash. Getting this backwards is asymmetric: a misread crash is hidden
// forever, a misread outage only costs a "Replay failed" banner. So the
// NEGATIVE cases below are the load-bearing ones.
//
// Shapes are read off the installed SDK's sdk.d.ts, not invented
// (feedback_inspect_real_data_before_tdd_fixtures): SDKResultError carries
// `terminal_reason` + `errors: string[]` and has NO `result`/`error` field —
// the first cut regexed `message.result ?? message.error` and was prod-dead.
const limitCases = [
  // positives
  [{ type: 'result', subtype: 'error_during_execution', terminal_reason: 'blocking_limit' }, true,
    'result terminal_reason=blocking_limit'],
  [{ type: 'result', subtype: 'error_during_execution', terminal_reason: 'rapid_refill_breaker' }, true,
    'result terminal_reason=rapid_refill_breaker'],
  [{ type: 'rate_limit_event', rate_limit_info: { status: 'rejected', rateLimitType: 'five_hour' } }, true,
    'rate_limit_event status=rejected'],
  [{ type: 'result', subtype: 'error_during_execution',
     errors: ['Claude AI usage limit reached|1753488000'] }, true,
    'result errors[] carries the CLI limit string'],
  [new Error('Claude Code process exited with code 1\nClaude AI usage limit reached|1753488000'), true,
    'thrown process error whose message embeds the stderr limit tail'],
  // negatives — these MUST stay exit 3
  [{ type: 'rate_limit_event', rate_limit_info: { status: 'allowed_warning', utilization: 0.9 } }, false,
    'near the cap but still being served is not an outage'],
  [{ type: 'result', subtype: 'error_max_turns', errors: [] }, false,
    'error_max_turns is a real replay failure'],
  [{ type: 'result', subtype: 'error_during_execution', terminal_reason: 'api_error' }, false,
    'api_error must stay loud'],
  [new Error('ENOENT: no such file or directory, open \'/nope/transcript.jsonl\''), false,
    'ENOENT is a real crash'],
  [new Error('Cannot find module \'@anthropic-ai/claude-agent-sdk\''), false,
    'missing SDK is a real crash'],
  [null, false, 'null'],
  [undefined, false, 'undefined'],
];
for (const [input, want, label] of limitCases) {
  check(`limit signal: ${label} → ${want}`, isUsageLimitSignal(input) === want,
    `got ${isUsageLimitSignal(input)}, want ${want}`);
}

// ─── structural: the replay loop-breaker ────────────────────────────────
// SDK 0.3.x flipped the settingSources default from isolation to
// load-all-filesystem-settings, so every replay child ran the user's hooks:
// its own SessionEnd re-entered session-end.sh, the substance gate rescued
// it (1 turn but ≥25k chars of embedded transcript) and it replayed the
// replay — ×2 per generation, one per pass below. Observed 2026-07-25
// draining the whole 5h usage window. Both passes must opt out, and the
// env marker is the belt for a future SDK default change.
// Counted, not merely present: replaySrc is comment-stripped above, so a
// deleted option line can't be masked by the prose that describes it.
const settingHits = (replaySrc.match(/settingSources:\s*\[\s*\]/g) || []).length;
check('both replay passes disable filesystem settings', settingHits === 2,
  `found ${settingHits}, want 2 — a pass that loads settings runs our hooks and re-chains`);
check('replay.mjs marks its descendants with MP_REPLAY_CHILD',
  /process\.env\.MP_REPLAY_CHILD\s*=/.test(replaySrc),
  'env loop-breaker gone — hooks in SDK children cannot self-identify');

// Both bail-2 sites must route through the tested classifier, and the
// prod-dead field read that preceded it must not come back.
const limitHits = (replaySrc.match(/isUsageLimitSignal\(/g) || []).length;
check('replay.mjs classifies limits via the tested helper', limitHits >= 3,
  `found ${limitHits}, want >=3 (thrown err, error result, streamed event)`);
check('no inline limit regex left in replay.mjs', !/limit reached\|usage limit/.test(replaySrc),
  'duplicate untested classifier — one of the two will drift');
check('no read of the nonexistent result.error field',
  !/message\.result\s*\?\?\s*message\.error/.test(replaySrc),
  'SDKResultError has neither field — that branch can never fire');

console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
console.log(`${fail} FAILED`); process.exit(1);
