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

import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, existsSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';

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

// ─── structural: replay model is PINNED (env-overridable), not the alias ──
// Reversal of the 2026-06 "bare alias" contract, 2026-07-29: the alias
// floated to claude-sonnet-5 when the installed SDK updated, and Sonnet 5
// runs adaptive thinking BY DEFAULT when the request omits thinking config.
// Measured replay children: 60k-115k output tokens per pass (327-624s
// wall-clock) for ~500-token answers — thinking spend, not summary text.
// claude-sonnet-4-6 keeps thinking OFF when omitted and tokenizes ~30%
// smaller. MP_REPLAY_MODEL is the escape hatch (deprecation, haiku
// experiments) so the next model move is an env edit, not a code edit.
const modelHits = (replaySrc.match(/model:\s*MODEL\b/g) || []).length;
check('both replay passes use the shared MODEL const', modelHits === 2,
  `found ${modelHits}, want 2`);
check('MODEL defaults to pinned claude-sonnet-4-6',
  /MP_REPLAY_MODEL\s*\|\|\s*'claude-sonnet-4-6'/.test(replaySrc),
  'default drifted off the pin — see 2026-07-29 thinking-by-default incident');
check('bare sonnet alias gone from replay passes', !/model:\s*'sonnet'/.test(replaySrc),
  'alias present — floats to Sonnet 5, adaptive thinking on, 5-10x slower');

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
  // An api_retry is a 429 the SDK is HANDLING — the request has not failed.
  // Nested error text must not leak into the match if the classifier is ever
  // "improved" to flatten error objects.
  [{ type: 'system', subtype: 'api_retry', attempt: 1, max_retries: 3, error_status: 429,
     error: { message: 'rate_limit_error: usage limit reached' } }, false,
    'an api_retry the SDK is still retrying is not an outage'],
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
// The non-result limit branch must be gated on the message TYPE, not left to
// catch every message that is neither assistant nor result. The SDK union is
// ~40 types and growing (api_retry, informational, mirror_error all carry
// error/content strings); an ungated branch is one new type away from calling
// a real crash benign.
check('non-result limit branch is gated on rate_limit_event',
  /message\.type === 'rate_limit_event' && isUsageLimitSignal\(message\)/.test(replaySrc),
  'ungated else-if — every future SDK message type is a false-positive candidate');

// ─── behavioral: boot-context delivery must not wait for pass 2 ─────────
// The launcher only renames its stdout tmp at process EXIT, so emitting the
// boot context at the bottom of the script charged the next session the FULL
// cost of pass 2's second agent call — even though pass 1 had the summary
// minutes earlier (measured 2026-07-28: launch 15:25:25 → context on disk
// 15:30:23, 4m58s, on a 520KB transcript). replay.mjs must write
// $MP_BOOT_CTX itself, atomically, the moment pass 1 finishes. Real
// subprocess against a stubbed SDK (CLAUDE_AGENT_SDK) — the only way to
// observe the mid-flight ordering the fix is about.
const PASS2_MS = 2000;
const sbx = mkdtempSync(join(tmpdir(), 'mp-replay-'));
try {
  writeFileSync(join(sbx, 'sdk-stub.mjs'), `
import fs from 'node:fs';
export async function getSessionMessages() {
  return [
    { type: 'user', message: { role: 'user', content: 'real prompt' } },
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'did the work' }] } },
  ];
}
let calls = 0;
export async function* query(args) {
  calls++;
  fs.appendFileSync(process.env.MP_TEST_MODEL_LOG,
    ((args && args.options && args.options.model) || 'MISSING') + '\\n');
  if (calls === 1) {
    yield { type: 'result', subtype: 'success',
            result: 'TITLE: stub\\nSUMMARY: pass one done\\nTODO: none\\nDECISIONS: none' };
    return;
  }
  await new Promise(r => setTimeout(r, ${PASS2_MS}));
  yield { type: 'result', subtype: 'success', result: 'PROPOSAL\\ntype: reference\\nname: stub_fact' };
}
`);

  const projCwd = join(sbx, 'Proj');
  const memoryDir = join(sbx, '.claude', 'projects', projCwd.replace(/[\\/.]/g, '-'), 'memory');
  mkdirSync(memoryDir, { recursive: true });
  const bootCtx = join(sbx, '.boot-context-stub');
  const modelLog = join(sbx, 'models.log');
  const env = {
    ...process.env,
    HOME: sbx,
    CLAUDE_AGENT_SDK: join(sbx, 'sdk-stub.mjs'),
    MP_BOOT_CTX: bootCtx,
    MP_TEST_MODEL_LOG: modelLog,
    // Neutralize any real override in the invoking shell: '' is falsy, so
    // replay falls back to its pinned default — which is what run 1 asserts.
    MP_REPLAY_MODEL: '',
  };
  const REPLAY = join(HERE, '..', 'hooks', 'replay.mjs');

  const run = (extraEnv, onDeliver) => new Promise((resolve) => {
    const started = Date.now();
    let deliveredAt = null;
    const poll = setInterval(() => {
      if (deliveredAt === null && existsSync(bootCtx)) {
        deliveredAt = Date.now();
        if (onDeliver) onDeliver();
      }
    }, 25);
    const child = spawn(process.execPath, [REPLAY, 'sid-stub', projCwd],
      { env: { ...env, ...extraEnv }, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    child.stdout.on('data', (d) => { stdout += d; });
    child.on('close', (code) => {
      clearInterval(poll);
      resolve({ code, stdout, deliveredAt, exitedAt: Date.now(), started });
    });
  });

  const r = await run({});
  check('early delivery: replay exits 0 against the stub SDK', r.code === 0,
    `exit ${r.code}; stdout=${r.stdout.slice(0, 200)}`);
  const modelsR = existsSync(modelLog)
    ? readFileSync(modelLog, 'utf8').trim().split('\n') : [];
  check('model pin: both stub passes received claude-sonnet-4-6',
    modelsR.length === 2 && modelsR.every((m) => m === 'claude-sonnet-4-6'),
    `recorded: [${modelsR.join(', ')}]`);
  check('early delivery: boot context lands at $MP_BOOT_CTX', r.deliveredAt !== null,
    'file never appeared — replay still emits only on stdout at exit');
  if (r.deliveredAt !== null) {
    const lead = r.exitedAt - r.deliveredAt;
    check('early delivery: context lands BEFORE pass 2 finishes',
      lead >= PASS2_MS / 2,
      `context landed ${lead}ms before exit, want >=${PASS2_MS / 2}ms — pass 2 still gates delivery`);
    check('early delivery: delivered content is pass 1 output',
      /SUMMARY: pass one done/.test(readFileSync(bootCtx, 'utf8')),
      `got ${readFileSync(bootCtx, 'utf8').slice(0, 120)}`);
    check('early delivery: pass 2 still ran and appended proposals',
      existsSync(join(memoryDir, 'PENDING_MEMORIES.md')),
      'promotion pass did not write PENDING_MEMORIES.md');
  }

  // A consumed context must never be re-created: boot-inject renames the file
  // away once injected, and anything pass 2 writes afterwards would resurrect
  // a live context and re-inject the same summary into a later session.
  rmSync(bootCtx, { force: true });
  const r2 = await run({}, () => rmSync(bootCtx, { force: true }));
  check('early delivery: nothing resurrects a context consumed mid-pass-2',
    r2.code === 0 && !existsSync(bootCtx),
    `exit ${r2.code}; file back = ${existsSync(bootCtx)} — a later session re-injects this summary`);

  // No MP_BOOT_CTX (manual `node replay.mjs <sid> <cwd>`) → stdout, unchanged.
  // Piggybacks the MP_REPLAY_MODEL override: both passes must ride it.
  const r3 = await run({ MP_BOOT_CTX: '', MP_REPLAY_MODEL: 'test-model-override' });
  check('early delivery: stdout fallback survives for a manual run',
    /SUMMARY: pass one done/.test(r3.stdout),
    `stdout=${r3.stdout.slice(0, 200)}`);
  const allModels = existsSync(modelLog)
    ? readFileSync(modelLog, 'utf8').trim().split('\n') : [];
  check('model pin: MP_REPLAY_MODEL override reaches both passes',
    allModels.length === 6 && allModels.slice(-2).every((m) => m === 'test-model-override'),
    `recorded ${allModels.length} calls; last two: [${allModels.slice(-2).join(', ')}]`);
} finally {
  rmSync(sbx, { recursive: true, force: true });
}

console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
console.log(`${fail} FAILED`); process.exit(1);
