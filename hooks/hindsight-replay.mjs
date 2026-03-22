// Hindsight replay agent: reads session transcript, extracts a boot context
// summary, and retains key outcomes to Hindsight for long-term memory.
// Called by hindsight-session-end.sh at SessionEnd (detached via nohup).
// Usage: node hindsight-replay.mjs <session-id> <cwd>

import { getSessionMessages, query } from '/opt/homebrew/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs';
import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const sessionId = process.argv[2];
const cwd = process.argv[3] || process.cwd();
const project = cwd.split('/').pop();

// Read config
let HINDSIGHT_URL = 'http://10.147.18.236:8888/mcp/';
let BANK_ID = 'management';
try {
  const conf = readFileSync(join(__dirname, 'hindsight.conf'), 'utf8');
  const urlMatch = conf.match(/HINDSIGHT_URL="([^"]+)"/);
  if (urlMatch) HINDSIGHT_URL = urlMatch[1];
  const bankMatch = conf.match(/BANK_ID="([^"]+)"/);
  if (bankMatch) BANK_ID = bankMatch[1];
} catch {}

if (!sessionId) {
  process.exit(0);
}

// --- Helpers ---

async function hindsightRetain(content, tags = []) {
  try {
    const resp = await fetch(HINDSIGHT_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
      },
      body: JSON.stringify({
        jsonrpc: '2.0',
        id: Date.now(),
        method: 'tools/call',
        params: {
          name: 'retain',
          arguments: {
            content,
            bank_id: BANK_ID,
            context: 'session-replay',
            tags: [`project:${project}`, 'session:replay', ...tags],
          },
        },
      }),
    });
    await resp.text(); // consume response
  } catch (err) {
    process.stderr.write(`hindsight retain failed: ${err.message}\n`);
  }
}

// --- Main ---

// Read previous session messages
const msgs = await getSessionMessages(sessionId, { cwd });
if (!msgs || msgs.length === 0) {
  process.exit(0);
}

// Extract user/assistant text and detect mid-session retains
const conversation = [];
const midSessionRetains = [];
for (const m of msgs) {
  if (m.type === 'user' && typeof m.message?.content === 'string') {
    conversation.push(`USER: ${m.message.content}`);
  } else if (m.type === 'assistant') {
    let assistantText = '';
    for (const block of (m.message?.content || [])) {
      if (block.type === 'text' && block.text && !assistantText) {
        assistantText = block.text;
      }
      if (block.type === 'tool_use' && block.name?.includes('hindsight') && block.name?.includes('retain')) {
        const content = block.input?.content || '';
        if (content) midSessionRetains.push(content);
      }
    }
    if (assistantText) conversation.push(`ASSISTANT: ${assistantText}`);
  }
}

const transcript = conversation.join('\n');
if (!transcript.trim()) {
  process.exit(0);
}

const hadMidSessionRetains = midSessionRetains.length > 0;

// Build prompt — inform agent about mid-session retains
let retainInstruction;
if (hadMidSessionRetains) {
  retainInstruction = `The following outcomes were ALREADY retained to long-term memory during this session:
${midSessionRetains.map(r => `- ${r}`).join('\n')}

Only retain if there are significant outcomes NOT covered above. If the mid-session retains already cover the key work, output SKIP.`;
} else {
  retainInstruction = `Assess whether this session produced meaningful outcomes worth retaining to long-term memory. Retain if: bugs were fixed, features built, architecture decisions made, configurations changed, or knowledge was discovered. Skip if: session was just chat, reading, browsing, or trivial.`;
}

// Spawn replay agent — no MCP tools needed, just extract and output
for await (const message of query({
  prompt: `You are a session replay agent. Read this transcript from a previous Claude Code session and produce a boot context for the next session.

Project: ${project}
Session ID: ${sessionId}

Extract and output in this exact format:

TITLE: <short title of what was done>
SUMMARY: <1-3 sentence summary of the work>
TODO: <unfinished work or next steps, or "none">
DECISIONS: <key decisions made, pipe-separated, or "none">

${retainInstruction}

Final line must be either:
RETAIN: <concise summary of key outcomes (1-3 sentences)>
or:
SKIP: <brief reason>

TRANSCRIPT:
${transcript}`,
  options: {
    maxTurns: 1,
    model: 'claude-sonnet-4-6',
    systemPrompt: 'You are a session replay agent. Analyze the transcript and output the structured boot context. No tool calls needed — just output text.',
    permissionMode: 'bypassPermissions',
  }
})) {
  if (message.type === 'result' && message.subtype === 'success') {
    const result = message.result || '';

    // Check if the agent decided to retain
    const retainMatch = result.match(/RETAIN:\s*(.+)/s);
    if (retainMatch) {
      const retainContent = `Session ${sessionId.slice(0, 8)} (${project}): ${retainMatch[1].trim()}`;
      await hindsightRetain(retainContent);
    }

    // Output boot context: strip the RETAIN/SKIP instruction line, add retained status
    const bootLines = result.replace(/^(RETAIN|SKIP):.*$/ms, '').trimEnd();
    const retainedStatus = retainMatch ? 'yes' : 'no';
    console.log(`${bootLines}\nRETAINED: ${retainedStatus}`);
  }
}
