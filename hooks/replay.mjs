// Replay agent: reads session transcript and produces boot context for the
// next session, plus an optional memory-promotion proposal pass.
//
// Called by session-end.sh at SessionEnd (detached via nohup).
// Usage: node replay.mjs <session-id> <cwd>
//
// Two passes:
//   1. Boot-context extraction → stdout (consumed once by boot-inject.sh)
//   2. Memory-promotion → proposals appended to
//      ~/.claude/projects/<slug>/memory/PENDING_MEMORIES.md for human-in-the-
//      loop review by a future session.

import { resolveSdkSpecifier } from './_lib.mjs';
import fs from 'node:fs/promises';
import path from 'node:path';

// SDK location is host-dependent (Homebrew on macOS, npm-global or
// engine-local on Linux). Resolve portably instead of hardcoding a path.
const { getSessionMessages, query } = await import(resolveSdkSpecifier());

// Exit codes:
//   0 = success (boot context written to stdout)
//   2 = benign no-op (nothing to replay — not a failure)
//   3 = real failure (SDK error, empty result, thrown exception)
// session-end.sh reads the exit code to decide whether to surface a synthetic
// error boot-context and the "Replay failed" notification. Always write a
// one-line reason to stderr on every non-success path so /tmp/replay-error.log
// is never mysteriously empty.
const bail = (code, reason) => {
  process.stderr.write(`[replay] ${reason}\n`);
  process.exit(code);
};

const sessionId = process.argv[2];
const cwd = process.argv[3] || process.cwd();
const project = cwd.split('/').pop();

// Engine root is relocatable; prefer the explicit knob, else self-locate
// (this file physically lives in <root>/hooks/). Keeps the schema pointer
// shown to the promotion agent correct on any host.
const ENGINE_ROOT = process.env.MEMORY_PACK_HOME
  || path.join(path.dirname(new URL(import.meta.url).pathname), '..');
const SCHEMA_PATH = path.join(ENGINE_ROOT, 'SCHEMA.md');

if (!sessionId) {
  bail(2, 'no session id passed on argv — nothing to replay');
}

// Read previous session messages
const msgs = await getSessionMessages(sessionId, { cwd });
if (!msgs || msgs.length === 0) {
  bail(2, `getSessionMessages returned empty for session ${sessionId}`);
}

// Extract user/assistant text
const conversation = [];
for (const m of msgs) {
  if (m.type === 'user' && typeof m.message?.content === 'string') {
    conversation.push(`USER: ${m.message.content}`);
  } else if (m.type === 'assistant') {
    for (const block of (m.message?.content || [])) {
      if (block.type === 'text' && block.text) {
        conversation.push(`ASSISTANT: ${block.text}`);
        break;
      }
    }
  }
}

const transcript = conversation.join('\n');
if (!transcript.trim()) {
  bail(2, `transcript had ${msgs.length} raw messages but no user/assistant text — likely all tool calls`);
}

// ───────────────────────────────────────────────────────────────────────
// Shared context: per-project memory dir + recent-sessions timeline.
// Both passes consume `recentSessions` so they can detect continuity
// across prior sessions (e.g. "this is the 3rd session on the auth
// rewrite"). SESSIONS.md is maintained by boot-inject.sh.
// ───────────────────────────────────────────────────────────────────────
const slug = cwd.replace(/[/.]/g, '-');
const memoryDir = path.join(process.env.HOME, '.claude', 'projects', slug, 'memory');

let memoryDirExists = false;
try { await fs.access(memoryDir); memoryDirExists = true; } catch {}

let recentSessions = '';
if (memoryDirExists) {
  try {
    const raw = await fs.readFile(path.join(memoryDir, 'SESSIONS.md'), 'utf8');
    const entries = raw.split('\n').filter(l => /^\d{4}-\d{2}-\d{2}/.test(l));
    recentSessions = entries.slice(-10).join('\n');
  } catch {}
}
const recentSessionsBlock = recentSessions
  ? `Recent prior sessions in this project (newest last, from SESSIONS.md):\n${recentSessions}`
  : `No prior sessions recorded — this appears to be an early session in this project.`;

// ───────────────────────────────────────────────────────────────────────
// Pass 1: Boot context extraction
// ───────────────────────────────────────────────────────────────────────
let bootContext = '';
let lastResultSubtype = '';
// Collect any assistant text that streams through — used as a fallback
// when the result message doesn't arrive (e.g. error_max_turns). This way
// a near-complete answer still produces a boot context instead of getting
// discarded and replaced by the synthetic "Replay failed" banner.
let fallbackAssistantText = '';
for await (const message of query({
  prompt: `You are a session replay agent. Read this transcript from a previous Claude Code session and produce a boot context for the next session.

Project: ${project}
Session ID: ${sessionId}

${recentSessionsBlock}

Use the prior-sessions list to detect continuity. If the current session continues work from a recent prior session, reflect that in the SUMMARY ("continuing X from <date>" or "third session on Y") so the next session can thread the context.

Extract and output in this exact format:

TITLE: <short title of what was done>
SUMMARY: <1-3 sentence summary of the work, noting continuity with prior sessions when applicable>
TODO: <unfinished work or next steps, or "none">
DECISIONS: <key decisions made, pipe-separated, or "none">

TRANSCRIPT:
${transcript}`,
  options: {
    maxTurns: 6,
    model: 'claude-sonnet-4-6',
    systemPrompt: 'You are a session replay agent. Analyze the transcript and output the structured boot context on your first turn. No tool calls — just output text.',
    permissionMode: 'bypassPermissions',
    // Force text-only output. Without this the SDK enables the full Claude Code
    // toolset by default and sonnet burns maxTurns on Read/Grep exploration
    // instead of emitting the summary — producing error_max_turns with nothing
    // streamed to recover from.
    tools: [],
  }
})) {
  if (message.type === 'assistant') {
    for (const block of (message.message?.content || [])) {
      if (block.type === 'text' && block.text) {
        fallbackAssistantText = block.text;
      }
    }
  } else if (message.type === 'result') {
    lastResultSubtype = message.subtype || '';
    if (message.subtype === 'success') {
      bootContext = message.result || '';
    }
  }
}

if (!bootContext && /TITLE:/i.test(fallbackAssistantText) && /SUMMARY:/i.test(fallbackAssistantText)) {
  // Result message never arrived (likely error_max_turns) but the model did
  // stream a well-formed answer. Recover it instead of failing the whole pass.
  bootContext = fallbackAssistantText;
  process.stderr.write(
    `[replay] pass 1 recovered from assistant stream (subtype: ${lastResultSubtype || 'none'})\n`
  );
}

if (!bootContext) {
  // Don't bail yet — pass 2 may still produce useful proposals. Record the
  // reason so the final empty-output guard below can surface it.
  process.stderr.write(
    `[replay] pass 1 produced empty boot context (last result subtype: ${lastResultSubtype || 'none'})\n`
  );
}

// ───────────────────────────────────────────────────────────────────────
// Pass 2: Memory promotion proposals (best-effort; never blocks pass 1)
// ───────────────────────────────────────────────────────────────────────
let promotionSummary = '';
try {
  const indexPath = path.join(memoryDir, 'MEMORY.md');
  const pendingPath = path.join(memoryDir, 'PENDING_MEMORIES.md');

  if (memoryDirExists) {
    let existingIndex = '';
    try { existingIndex = await fs.readFile(indexPath, 'utf8'); } catch {}

    let existingFiles = [];
    try {
      existingFiles = (await fs.readdir(memoryDir))
        .filter(f => f.endsWith('.md') && !['MEMORY.md', 'sessions.log.md', 'PENDING_MEMORIES.md'].includes(f))
        .sort();
    } catch {}

    const today = new Date().toISOString().slice(0, 10);

    const promotionPrompt = `You are a memory-promotion agent. Read this session transcript and propose ZERO OR MORE durable facts worth saving to the per-project auto-memory store.

Project: ${project}
Session ID: ${sessionId}
Today: ${today}

${recentSessionsBlock}

Use the prior-sessions list to detect RECURRING themes: a fact that shows up across 2+ sessions is stronger evidence it is durable and worth promoting. A fact that appears only in this one session should face a higher bar.

DEFAULT OUTPUT: the literal word "NONE" on a single line.

Propose a memory ONLY if the transcript contains a fact that meets ALL of:
1. Not already covered by the existing memory index below
2. Will still be true and useful in future sessions (durable, not ephemeral)
3. NOT derivable from reading code, git log, or git blame
4. NOT a code pattern, convention, architecture detail, or file path
5. NOT a fix recipe or debugging solution (the fix lives in the commit)
6. NOT current-conversation state (in-progress work, scratchpad context)

PREFER SILENCE. A missed memory is fine; a noisy memory is costly. When in doubt, emit NONE.

Valid types (canonical semantics: ${SCHEMA_PATH}):
- user      — durable attributes of the user (role, expertise, responsibilities)
- feedback  — corrections OR confirmed non-obvious approaches
- project   — who/why/when of ongoing work (convert relative dates to absolute; today is ${today})
- reference — pointers to external systems (dashboards, APIs, hosts, tickets)

Body structure rules:
- feedback: lead with the rule, then a **Why:** line (reason the user gave) and a **How to apply:** line (when the rule kicks in)
- project:  lead with the fact, then **Why:** (motivation/constraint/stakeholder) and **How to apply:** (how it shapes future suggestions)
- user:     a short paragraph describing the attribute
- reference: a short paragraph describing the external pointer and when to use it

EXISTING MEMORY INDEX (${indexPath}):
${existingIndex || "(empty)"}

EXISTING MEMORY FILES:
${existingFiles.length ? existingFiles.join(', ') : "(none)"}

OUTPUT FORMAT — either the literal "NONE", or one or more proposal blocks separated by a blank line, each matching EXACTLY:

PROPOSAL
type: <user|feedback|project|reference>
name: <snake_case_filename.md>
description: <one-line index description, ≤150 chars, will be copied verbatim into MEMORY.md>
rationale: <why this is durable AND why it is not a duplicate of an existing file>
---
<proposed body, following the body_structure rules above>
---

TRANSCRIPT:
${transcript}`;

    let promotionResult = '';
    let promotionFallback = '';
    for await (const message of query({
      prompt: promotionPrompt,
      options: {
        maxTurns: 6,
        model: 'claude-sonnet-4-6',
        systemPrompt: 'You are a strict memory-promotion agent. Default to NONE. Only emit proposals for durable, non-derivable, non-duplicate facts. No tool calls — text output only.',
        permissionMode: 'bypassPermissions',
        // See pass-1 comment: tools: [] forces the model to emit text instead
        // of exploring via Read/Grep and hitting error_max_turns.
        tools: [],
      }
    })) {
      if (message.type === 'assistant') {
        for (const block of (message.message?.content || [])) {
          if (block.type === 'text' && block.text) {
            promotionFallback = block.text;
          }
        }
      } else if (message.type === 'result' && message.subtype === 'success') {
        promotionResult = (message.result || '').trim();
      }
    }
    if (!promotionResult && promotionFallback) {
      // Recover from error_max_turns etc. — treat a well-formed assistant
      // stream as good enough. If it's garbage, the PROPOSAL regex below
      // will count zero proposals and the block becomes a no-op.
      promotionResult = promotionFallback.trim();
    }

    const proposalCount = (promotionResult.match(/^PROPOSAL$/gm) || []).length;
    if (proposalCount > 0 && promotionResult.toUpperCase().trim() !== 'NONE') {
      const now = new Date().toISOString().replace('T', ' ').slice(0, 16) + ' UTC';
      const header = `# Pending Memory Proposals

Proposals from session replay agents, awaiting review by a future session.
Each proposal is a durable fact the replay agent judged worth saving but
could not commit directly (replay runs detached with no read access to
existing memory bodies — only the index).

## Review protocol

When you see this file in a session:
1. Read each PROPOSAL below.
2. Compare it against the memory files already in this directory (read
   the actual files, not just the index).
3. For each proposal, choose ONE:
   - **Create** a new memory file using the proposed type/name/body.
     Verify against the canonical schema at
     \`${SCHEMA_PATH}\` and add a pointer line to
     \`MEMORY.md\` in the right section.
   - **Merge** into an existing memory on the same topic.
   - **Discard** (noise, ephemeral, already known, or no longer true).
4. Delete the proposal block from this file after acting on it.
5. Delete this file entirely once no proposals remain.

Not a memory file — \`memory-lint\` ignores this path.

---
`;

      let existing = '';
      try { existing = await fs.readFile(pendingPath, 'utf8'); } catch {}

      const block = `\n## Proposals from session ${sessionId} — ${now}\n\n${promotionResult}\n`;
      if (!existing) {
        await fs.writeFile(pendingPath, header + block);
      } else {
        await fs.appendFile(pendingPath, block);
      }

      promotionSummary = `PENDING_MEMORIES: ${proposalCount} proposal${proposalCount === 1 ? '' : 's'} appended to memory/PENDING_MEMORIES.md — review per protocol at top of file.`;
    }
  }
} catch (err) {
  process.stderr.write(`[replay] promotion pass failed: ${err?.message || err}\n`);
}

// ───────────────────────────────────────────────────────────────────────
// Output: boot context (consumed by boot-inject.sh) + optional pending note
// ───────────────────────────────────────────────────────────────────────
if (bootContext) {
  console.log(bootContext);
  if (promotionSummary) {
    console.log('');
    console.log(promotionSummary);
  }
} else {
  // Reached end with nothing to emit. stderr already has pass 1's reason;
  // exit 3 signals "real failure" so session-end.sh surfaces the synthetic
  // error boot-context (exit 2 would be a benign no-op).
  process.exit(3);
}
