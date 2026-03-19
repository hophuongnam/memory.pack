# Memory Pack

Session continuity + long-term memory system for Claude Code projects.

Uses **Hindsight** for long-term memory (retain / recall / reflect via MCP).

## Architecture

```
Stop hook → session-marker.sh → writes session_id (if >5 user turns)

Next session start → hindsight-session-start.sh (backgrounds, instant return)
  → hindsight-replay.mjs:
    1. Read previous transcript (Agent SDK)
    2. Sonnet summarizes → text (TITLE, SUMMARY, TODO, DECISIONS)
    3. Assesses whether session is worth retaining
    4. If RETAIN: sends summary to Hindsight via direct HTTP
    5. Outputs boot context to file

Next user message → hindsight-boot-inject.sh → injects boot context via additionalContext
```

Optional: `hindsight-retain.sh` — Stop hook that blocks agent to assess whether
code changes since last retain need to be retained to Hindsight.

## Project Structure

```
hooks/          — Claude Code hook scripts (source of truth)
skills/         — SKILL.md files for Hindsight
docs/           — Architecture documentation
```

## Dependencies

- `@anthropic-ai/claude-agent-sdk` (npm global) — Agent SDK for replay agent
- Hindsight server at URL configured in `hooks/hindsight.conf`
- `jq` — JSON parsing in shell hooks

## Deployment

Hook files are copied (or symlinked) to each project's `.claude/hooks/` directory.
Per-project config goes in `hooks/hindsight.conf` (BANK_ID, HINDSIGHT_URL).

## Key Design Decisions

- No "session end" event — each session retroactively closes the previous one
- Replay agent uses `nohup` to fully detach from hook runner (instant startup)
- Atomic rename: boot context written to `.tmp` then `mv` to final path (avoids race with inject hook)
- Trivial sessions (≤5 user turns) are skipped by the marker hook
- Self-replay guard: skips replay when stored session ID matches current session ID
- Retain is done by replay agent via direct HTTP to Hindsight (no MCP tools needed)
- LLM (Sonnet) assesses whether session is worth retaining
- Replay agent uses `maxTurns: 1` — no tool calls, just text output
