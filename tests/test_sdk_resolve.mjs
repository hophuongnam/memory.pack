// TDD: portable claude-agent-sdk resolution for replay.mjs.
// replay.mjs hardcoded /opt/homebrew/... (macOS Homebrew), which does not
// exist on Linux -> replay hard-fails on every deployed host. A pure
// resolveSdkSpecifier({env, exists}) (DI'd exists for testability) must
// pick: explicit env override > MEMORY_PACK_HOME-local install > known
// global npm roots > bare specifier (Node resolver last resort), and stay
// value-preserving on this Mac (still picks the Homebrew path).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(HERE, '..', 'hooks', '_lib.mjs');

const { resolveSdkSpecifier } = await import(LIB); // fails RED until _lib.mjs exists

let fail = 0;
const ok = (m) => console.log('PASS  ' + m);
const bad = (m, e, g) => { console.log(`FAIL  ${m}\n      exp[${e}] got[${g}]`); fail++; };
const eq = (m, e, g) => (e === g ? ok(m) : bad(m, e, g));

const BREW  = '/opt/homebrew/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';
const ULOC  = '/usr/local/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';
const ULIB  = '/usr/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';
const BARE  = '@anthropic-ai/claude-agent-sdk/sdk.mjs';
const only  = (...set) => (p) => set.includes(p);

// explicit env override wins when it exists
eq('env override exists -> used', '/x/sdk.mjs',
   resolveSdkSpecifier({ env: { CLAUDE_AGENT_SDK: '/x/sdk.mjs' }, exists: only('/x/sdk.mjs') }));

// env override set but missing -> ignored, falls through to bare (nothing else exists)
eq('env override missing -> fallthrough', BARE,
   resolveSdkSpecifier({ env: { CLAUDE_AGENT_SDK: '/x/sdk.mjs' }, exists: () => false }));

// macOS value-preservation: only Homebrew path exists -> pick it
eq('mac brew path preserved', BREW,
   resolveSdkSpecifier({ env: {}, exists: only(BREW) }));

// Linux global npm roots
eq('linux /usr/local global', ULOC, resolveSdkSpecifier({ env: {}, exists: only(ULOC) }));
eq('linux /usr/lib global',   ULIB, resolveSdkSpecifier({ env: {}, exists: only(ULIB) }));

// engine-local install under MEMORY_PACK_HOME
const MPH = '/mp';
const MPHSDK = '/mp/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';
eq('MEMORY_PACK_HOME-local install', MPHSDK,
   resolveSdkSpecifier({ env: { MEMORY_PACK_HOME: MPH }, exists: only(MPHSDK) }));

// precedence: env > MPH-local > brew when several exist
eq('precedence env beats all', '/ovr.mjs',
   resolveSdkSpecifier({ env: { CLAUDE_AGENT_SDK: '/ovr.mjs', MEMORY_PACK_HOME: MPH },
                         exists: only('/ovr.mjs', MPHSDK, BREW) }));
eq('precedence MPH beats brew', MPHSDK,
   resolveSdkSpecifier({ env: { MEMORY_PACK_HOME: MPH }, exists: only(MPHSDK, BREW) }));

// nothing exists -> bare specifier (Node resolver / NODE_PATH last resort)
eq('nothing exists -> bare', BARE,
   resolveSdkSpecifier({ env: {}, exists: () => false }));

// structural: replay.mjs no longer hardcodes the Homebrew path and uses the resolver
const replay = readFileSync(join(HERE, '..', 'hooks', 'replay.mjs'), 'utf8');
(!replay.includes('/opt/homebrew/lib/node_modules'))
  ? ok('replay.mjs: Homebrew hardcode removed')
  : bad('replay.mjs: Homebrew hardcode removed', 'absent', 'present');
(replay.includes('resolveSdkSpecifier') && /_lib\.mjs/.test(replay))
  ? ok('replay.mjs: uses resolveSdkSpecifier from _lib.mjs')
  : bad('replay.mjs: uses resolveSdkSpecifier from _lib.mjs', 'yes', 'no');

console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
else { console.log(fail + ' FAILED'); process.exit(1); }
