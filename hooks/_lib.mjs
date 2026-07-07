// Memory.Pack shared Node helpers. Imported by .mjs hooks via a relative
// specifier (`./_lib.mjs`, always co-located → portable); never executed
// directly. Leading-underscore name mirrors _lib.sh.
import { existsSync, statSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';

const SDK_REL = 'node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';
const SDK_PKG = '@anthropic-ai/claude-agent-sdk/sdk.mjs';

// fmParse / fmSetInPlace / fmSerialize — the one sanctioned way for engine
// code to touch memory-file frontmatter. Contract (SCHEMA.md; pinned by
// test_recall_frontmatter_preserve + test_archive_resurrect_preserve):
// shapes are tolerated on READ (flat, the stock system-prompt's nested
// `metadata:` wrapper, harness-injected `node_type:`), and NEVER reshaped
// on write — a targeted set leaves every other byte exactly as the
// author/harness wrote it. archive-resurrect.mjs used to re-serialize from
// a column-0-keys-only map, silently DELETING nested children; these
// helpers exist so no second parser can drift like that again.
//
// fmParse(text) → { lines, keys, rest, eol } | null
//   lines: frontmatter lines verbatim (no '---' fences; CRLF files keep
//          each line's trailing \r — lines are never reshaped)
//   keys:  Map of key → value, leading-whitespace-tolerant, trailing-\r
//          stripped on the VALUE read only; on duplicate keys the LAST
//          occurrence wins (and fmSetInPlace writes the LAST — read/write
//          must target the same line or counters freeze)
//   rest:  body after the closing fence
//   eol:   fence line ending ('\n' or '\r\n') — pass to fmSerialize for a
//          byte-identical round-trip
//   null when the text has no well-formed frontmatter block.
// Empty frontmatter (`---\n---\n`) parses as lines=[] — the close-fence
// search starts at index 3 so the IMMEDIATE fence wins over a later body
// `---` hr (searching from 4 spliced recall counters into the body).
export function fmParse(text) {
  if (typeof text !== 'string') return null;
  let open, eol;
  if (text.startsWith('---\n')) { open = 4; eol = '\n'; }
  else if (text.startsWith('---\r\n')) { open = 5; eol = '\r\n'; }
  else return null;
  const closePat = `\n---${eol}`;
  const end = text.indexOf(closePat, open - 1);
  if (end < 0) return null;
  const lines = end === open - 1 ? [] : text.slice(open, end).split('\n');
  const rest = text.slice(end + closePat.length);
  const keys = new Map();
  for (const line of lines) {
    // Strip the trailing \r from a COPY before matching: JS `.` treats \r
    // as a line terminator and `$` anchors only at true end-of-string, so
    // `(.*)$` never matches a CRLF line at all. `lines` stays verbatim.
    const m = line.replace(/\r$/, '').match(/^\s*([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$/);
    if (m) keys.set(m[1], m[2]);
  }
  return { lines, keys, rest, eol };
}

// fmSetInPlace(lines, key, value): rewrite ONLY the LAST line carrying
// `key` (fmParse reads the last occurrence — writing any other line would
// freeze the value), preserving its existing indentation and trailing \r;
// append at column 0 when the key is absent. Mutates `lines` in place.
export function fmSetInPlace(lines, key, value) {
  let hit = -1;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^(\s*)([A-Za-z_][A-Za-z0-9_]*):/);
    if (m && m[2] === key) hit = i;
  }
  if (hit >= 0) {
    const indent = lines[hit].match(/^(\s*)/)[1];
    const cr = lines[hit].endsWith('\r') ? '\r' : '';
    lines[hit] = `${indent}${key}: ${value}${cr}`;
    return;
  }
  lines.push(`${key}: ${value}`);
}

// fmSerialize(lines, rest, eol): reassemble exactly what fmParse split.
export function fmSerialize(lines, rest, eol = '\n') {
  if (lines.length === 0) return `---${eol}---${eol}${rest}`;
  return `---${eol}${lines.join('\n')}\n---${eol}${rest}`;
}

// appendAudit(logPath, line): append to a dotfile audit log with a size
// cap. Audit logs (.archive-promote.log / .archive-resurrect.log) append
// one line per event and previously grew forever (runtime-state-GC class).
// Past maxBytes only the newest keepLines survive — these logs are a
// recent-events tail, not an archive. Rotation is check-then-act;
// concurrent writers can race it, but this is audit/display state where
// last-writer-wins is fine, and rotation must never block the append.
export function appendAudit(logPath, line, { maxBytes = 65536, keepLines = 200 } = {}) {
  try {
    if (existsSync(logPath) && statSync(logPath).size > maxBytes) {
      const kept = readFileSync(logPath, 'utf8').split('\n').slice(-keepLines).join('\n');
      writeFileSync(logPath, kept === '' || kept.endsWith('\n') ? kept : kept + '\n');
    }
  } catch {
    // best-effort rotation
  }
  appendFileSync(logPath, line);
}

// extractConversation: flatten CC session messages into "USER:/ASSISTANT:"
// transcript lines for the replay/promotion agents.
//
// A user entry contributes ONLY when it is a real prompt:
//   * isMeta:true entries are skipped FIRST — CC bookkeeping and our own
//     auto-save-stop feedback arrive as isMeta user entries (string AND
//     huge array-text skill blobs); feeding them to the agents pollutes
//     the summary (reference_cc_transcript_isMeta_mid_turn.md).
//   * string content is a prompt; array content is a prompt only when it
//     carries no tool_result block (tool_results come back as user-type
//     entries) — its text blocks are joined. Mirrors log-token-rate.sh's
//     mutation-pinned is_user_prompt and _lib.sh _mp_real_user_turns /
//     _mp_conversation_chars (the trivial-skip substance gate);
//     keep the four in sync.
// An assistant entry contributes its FIRST text block (thinking/tool_use
// blocks are not conversation).
export function extractConversation(msgs) {
  const out = [];
  for (const m of msgs || []) {
    if (m?.type === 'user') {
      if (m.isMeta) continue;
      const c = m.message?.content;
      if (typeof c === 'string') {
        out.push(`USER: ${c}`);
      } else if (Array.isArray(c)) {
        if (c.some((b) => b?.type === 'tool_result')) continue;
        const text = c
          .filter((b) => b?.type === 'text' && b.text)
          .map((b) => b.text)
          .join('\n');
        if (text) out.push(`USER: ${text}`);
      }
    } else if (m?.type === 'assistant') {
      for (const block of m.message?.content || []) {
        if (block?.type === 'text' && block.text) {
          out.push(`ASSISTANT: ${block.text}`);
          break;
        }
      }
    }
  }
  return out.join('\n');
}

// truncateConversation: bound a transcript before embedding it in a model
// prompt. Without this, a long session blows the replay prompt past the
// model context → API error → exit 3 → the synthetic "Replay failed"
// banner replaces the summary — the longest sessions are exactly the ones
// most worth summarizing. Keep the head (how the session started) and the
// tail (most recent work, where TODO/DECISIONS live) around an explicit
// elision marker. Defaults ≈200k chars (~50k tokens): far under the model
// limit with room for the prompt scaffold, generous for real sessions.
export function truncateConversation(text, { head = 30_000, tail = 170_000 } = {}) {
  if (typeof text !== 'string') return '';
  if (text.length <= head + tail) return text;
  const elided = text.length - head - tail;
  return (
    text.slice(0, head) +
    `\n[... ${elided} characters elided (transcript too long for replay) ...]\n` +
    text.slice(text.length - tail)
  );
}

// Resolve an importable specifier for @anthropic-ai/claude-agent-sdk.
// replay.mjs previously hardcoded the macOS Homebrew absolute path, which
// does not exist on Linux. Precedence:
//   1. $CLAUDE_AGENT_SDK explicit override (if the file exists)
//   2. $MEMORY_PACK_HOME-local install (engine-bundled by install.sh)
//   3. known global npm roots (macOS Homebrew, Linux /usr/local, /usr/lib,
//      Windows %APPDATA%\npm)
//   4. bare package specifier — let Node's resolver / NODE_PATH try last
// `exists` is dependency-injected for testability (default fs.existsSync).
export function resolveSdkSpecifier({ env = process.env, exists = existsSync } = {}) {
  const ovr = env.CLAUDE_AGENT_SDK;
  if (ovr && exists(ovr)) return ovr;

  const candidates = [];
  if (env.MEMORY_PACK_HOME) candidates.push(`${env.MEMORY_PACK_HOME}/${SDK_REL}`);
  candidates.push(
    `/opt/homebrew/lib/${SDK_REL}`, // macOS Homebrew global
    `/usr/local/lib/${SDK_REL}`,    // Linux npm global (common)
    `/usr/lib/${SDK_REL}`,          // Linux npm global (distro)
  );
  // Windows npm global root. Guarded: the candidate is only formed when
  // APPDATA is set, so on POSIX (APPDATA undefined) this is a no-op and
  // every existing macOS/Linux resolution stays byte-identical. Lowest
  // precedence — appended after the unix globals — so it can never
  // subvert an existing hit. Node accepts '/' on Windows.
  if (env.APPDATA) candidates.push(`${env.APPDATA}/npm/${SDK_REL}`);
  for (const c of candidates) if (exists(c)) return c;

  return SDK_PKG;
}
