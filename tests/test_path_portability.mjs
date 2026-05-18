// TDD: POSIX-path portability hardening for the .mjs hooks. These scripts
// have top-level await + fs side effects (not unit-testable like the pure
// resolveSdkSpecifier), so — exactly as test_sdk_resolve.mjs:62-69 already
// does for replay.mjs — we assert the source no longer hard-codes
// POSIX-only constructs and uses the portable form instead. Every fix here
// is ALSO a latent POSIX-correctness fix, so it is zero-downside on
// Linux/WSL, not merely Windows-forward:
//   * process.env.HOME        -> os.homedir()            (HOME unset on Win)
//   * import.meta.url.pathname -> fileURLToPath(...)      (.pathname URL-
//        encodes spaces -> a wrong engine path even on POSIX if the install
//        dir contains a space)
//   * cwd.split('/')          -> path.basename(cwd)       (separator-aware)
//   * slug /[/.]/g            -> /[\\/.]/g                 (strict superset;
//        POSIX byte-identical — POSIX paths contain no backslash)
//   * endsWith('/archive')    -> basename(dir)==='archive' (separator-aware)
//
// Out of scope (documented native-Windows boundary, NOT fixed here because
// it is POSIX-correct as-is and WSL/Linux — the supported path — is POSIX):
// update-recall.mjs's '/memory/archive/' string surgery, python3-vs-python.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
// Scan CODE only, not prose: migration-documentation comments legitimately
// name the old POSIX construct ("os.homedir() replaces process.env.HOME").
// Same principle as test_mph_resolution.sh:64-67, which excludes comment
// lines so it asserts about executable code, not explanatory text. Drops
// full-line // and /* * */ comment lines (these hooks use no inline
// trailing comment that contains a scanned needle).
const codeOnly = (src) =>
  src.split('\n')
     .filter((l) => !/^\s*(\/\/|\/?\*)/.test(l))
     .join('\n');
const read = (rel) =>
  codeOnly(readFileSync(join(HERE, '..', 'hooks', rel), 'utf8'));

let fail = 0;
const ok = (m) => console.log('PASS  ' + m);
const bad = (m, d) => { console.log(`FAIL  ${m}\n      ${d}`); fail++; };
const absent = (label, src, needle) =>
  src.includes(needle) ? bad(label, `must NOT contain: ${needle}`) : ok(label);
const present = (label, src, needle) =>
  src.includes(needle) ? ok(label) : bad(label, `must contain: ${needle}`);

const replay = read('replay.mjs');
absent ('replay.mjs: no process.env.HOME',          replay, 'process.env.HOME');
present('replay.mjs: uses os.homedir()',            replay, 'os.homedir()');
absent ('replay.mjs: no import.meta.url .pathname', replay, 'import.meta.url).pathname');
present('replay.mjs: uses fileURLToPath',           replay, 'fileURLToPath(import.meta.url)');
absent ('replay.mjs: no cwd.split("/")',            replay, "cwd.split('/')");
present('replay.mjs: uses path.basename(cwd)',      replay, 'path.basename(cwd)');
absent ('replay.mjs: slug not POSIX-only /[/.]/g',  replay, 'cwd.replace(/[/.]/g');
present('replay.mjs: slug separator-aware [\\\\/.]', replay, '[\\\\/.]');

const ur = read('update-recall.mjs');
absent ('update-recall.mjs: no import.meta.url .pathname', ur, 'import.meta.url).pathname');
present('update-recall.mjs: uses fileURLToPath',           ur, 'fileURLToPath(import.meta.url)');

const ar = read('archive-resurrect.mjs');
absent ('archive-resurrect.mjs: no endsWith("/archive")', ar, "endsWith('/archive')");
present('archive-resurrect.mjs: basename(memDir) check',  ar, "basename(memDir) === 'archive'");

console.log('----');
if (fail === 0) { console.log('ALL PASS'); process.exit(0); }
else { console.log(fail + ' FAILED'); process.exit(1); }
