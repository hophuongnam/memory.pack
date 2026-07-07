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
import { readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, '..', 'hooks', 'replay.mjs');

let fail = 0;
const ok = (m) => console.log('PASS  ' + m);
const bad = (m, e, g) => { console.log(`FAIL  ${m}\n      exp[${e}] got[${g}]`); fail++; };
const has = (m, hay, needle) =>
  (hay.includes(needle) ? ok(m) : bad(m, `contains "${needle}"`, 'absent'));
const eq = (m, e, g) => (e === g ? ok(m) : bad(m, e, g));

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

// ─────────────────────────────────────────────────────────────────────────
// Structural pins: replay.mjs failure paths must be SELF-REPORTING.
// ─────────────────────────────────────────────────────────────────────────

// (1) The pass-2 catch must set promotionSummary to a failure line that
// flows into boot-context stdout. A stderr-only catch dies invisibly:
// session-end.sh deletes ERR_LOG on exit 0, so the proposals subsystem can
// be dead forever with zero surface.
/catch \(err\) \{[\s\S]{0,600}?promotionSummary = /.test(src)
  ? ok('pass-2 catch assigns a promotionSummary failure line')
  : bad('pass-2 catch assigns a promotionSummary failure line',
        'assignment inside catch', 'stderr-only catch');
has('failure line names the promotion pass', src, 'promotion pass FAILED');

// (2) PENDING_MEMORIES.md writes must be append-only. The old writeFile
// branch was a check-then-act race: two same-project session-ends both see
// "no file" and the second writeFile CLOBBERS the first's proposals.
// appendFile(header+block) worst-cases as a duplicated header — never lost
// proposals.
(!/writeFile\(pendingPath/.test(src))
  ? ok('no fs.writeFile on pendingPath (race-safe append-only)')
  : bad('no fs.writeFile on pendingPath', 'appendFile only', 'writeFile found');
has('missing-file branch appends header+block', src,
    'appendFile(pendingPath, header + block)');

// ─────────────────────────────────────────────────────────────────────────
// Behavioral: run the REAL replay.mjs against a stub SDK.
// CLAUDE_AGENT_SDK (resolveSdkSpecifier's explicit-override branch) points
// at a stub whose behavior is selected by MP_STUB_MODE. HOME points into
// the sandbox so the pass-2 memory dir is fully isolated.
//
// Exit-code contract: a session that reaches replay.mjs already PASSED
// session-end's substance gate — the gate counted real turns from the same
// transcript. So "SDK sees nothing" (empty messages / zero conversation
// text) is a REAL failure that must exit 3 (loud, error log kept), not 2
// (quiet carry-forward, error log deleted, recurs invisibly forever).
// RED: both cases exited 2.
// ─────────────────────────────────────────────────────────────────────────
{
  const tmp = mkdtempSync(join(tmpdir(), 'mp-replay-'));
  const STUB = join(tmp, 'stub-sdk.mjs');
  writeFileSync(STUB, `
const mode = process.env.MP_STUB_MODE || 'empty';
let call = 0;
export async function getSessionMessages() {
  if (mode === 'empty') return [];
  if (mode === 'toolsonly') return [
    { type: 'user', message: { content: [{ type: 'tool_result', content: 'x' }] } },
  ];
  return [
    { type: 'user', message: { content: 'do the thing' } },
    { type: 'assistant', message: { content: [{ type: 'text', text: 'did the thing' }] } },
  ];
}
export async function* query() {
  call++;
  if (call === 1) {
    yield { type: 'result', subtype: 'success',
            result: 'TITLE: stub\\nSUMMARY: stub summary\\nTODO: none\\nDECISIONS: none' };
    return;
  }
  if (mode === 'promofail') throw new Error('stub promotion boom');
  yield { type: 'result', subtype: 'success',
          result: 'PROPOSAL\\ntype: feedback\\nname: stub_prop.md\\ndescription: stub proposal\\nrationale: r\\n---\\nbody\\n---' };
}
`);

  const REPLAY = join(HERE, '..', 'hooks', 'replay.mjs');
  const home = join(tmp, 'home');
  const proj = join(tmp, 'proj');
  const slug = proj.replace(/[\\/.]/g, '-');
  const memDir = join(home, '.claude', 'projects', slug, 'memory');
  mkdirSync(memDir, { recursive: true });
  mkdirSync(proj, { recursive: true });

  const runReplay = (mode, sid) => {
    const env = { ...process.env, CLAUDE_AGENT_SDK: STUB, MP_STUB_MODE: mode, HOME: home };
    try {
      const stdout = execFileSync('node', [REPLAY, sid, proj], { encoding: 'utf8', env });
      return { code: 0, stdout, stderr: '' };
    } catch (e) {
      return {
        code: e.status,
        stdout: e.stdout ? e.stdout.toString() : '',
        stderr: e.stderr ? e.stderr.toString() : '',
      };
    }
  };

  // Empty messages after a passed gate → REAL failure.
  const empty = runReplay('empty', 'sid-empty');
  eq('behavioral: empty getSessionMessages exits 3', 3, empty.code);
  has('behavioral: empty-messages reason on stderr', empty.stderr,
      'getSessionMessages returned empty');

  // Messages exist but zero conversation text → same class.
  const tools = runReplay('toolsonly', 'sid-tools');
  eq('behavioral: tool-result-only transcript exits 3', 3, tools.code);
  has('behavioral: no-text reason on stderr', tools.stderr,
      'no user/assistant text');

  // Pass 2 throws → boot context still emitted (exit 0) WITH a visible
  // failure line carrying the error message.
  const pf = runReplay('promofail', 'sid-pf');
  eq('behavioral: promotion failure still exits 0', 0, pf.code);
  has('behavioral: boot context present', pf.stdout, 'TITLE: stub');
  has('behavioral: promotion failure line in stdout', pf.stdout,
      'promotion pass FAILED');
  has('behavioral: failure line carries the error message', pf.stdout,
      'stub promotion boom');

  // Two sessions appending proposals: ONE header, BOTH blocks survive.
  const p1 = runReplay('proposal', 'sid-p1');
  const p2 = runReplay('proposal', 'sid-p2');
  eq('behavioral: proposal run 1 exits 0', 0, p1.code);
  eq('behavioral: proposal run 2 exits 0', 0, p2.code);
  has('behavioral: proposal run reports the append', p1.stdout,
      'PENDING_MEMORIES: 1 proposal appended');
  const pendingPath = join(memDir, 'PENDING_MEMORIES.md');
  if (!existsSync(pendingPath)) {
    bad('behavioral: PENDING_MEMORIES.md written', 'exists', 'missing');
  } else {
    const pending = readFileSync(pendingPath, 'utf8');
    eq('behavioral: exactly one header across two appends', 1,
       (pending.match(/^# Pending Memory Proposals$/gm) || []).length);
    eq('behavioral: both session blocks survive', 2,
       (pending.match(/^## Proposals from session /gm) || []).length);
    has('behavioral: proposal body present', pending, 'stub_prop.md');
  }

  rmSync(tmp, { recursive: true, force: true });
}

console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
else { console.log(fail + ' FAILED'); process.exit(1); }
