# Memory Pack

Session continuity + auto-save tooling for Claude Code. Wired globally from
`~/.claude/settings.json` — the hooks in `hooks/` are called by absolute path,
not symlinked into each project.

## Active hooks

| Event              | Script              | Purpose                                                      |
|--------------------|---------------------|--------------------------------------------------------------|
| `Stop`             | `auto-save-stop.sh` | Every 30 user turns, block and tell Claude to save memory    |
| `SessionEnd`       | `session-end.sh`    | Detach `replay.mjs` via nohup; it writes next boot context   |
| `SessionStart`     | `boot-inject.sh`    | Inject previous session's boot context via `additionalContext` |
| `UserPromptSubmit` | `boot-inject.sh`    | Fallback inject; polls up to 5s if replay still running      |

## Flow

```
Session N ends
  └─ session-end.sh
       ├─ skip if ≤5 user turns
       └─ nohup node replay.mjs <session-id> <cwd>
             ├─ getSessionMessages() via @anthropic-ai/claude-agent-sdk
             ├─ Sonnet 4.6, maxTurns:1 → TITLE / SUMMARY / TODO / DECISIONS
             └─ stdout → .boot-context-<hash>.tmp → atomic mv

Session N+1 starts (same project)
  └─ boot-inject.sh (SessionStart, then UserPromptSubmit)
       ├─ hash cwd → read .boot-context-<hash>
       ├─ if replay still running: poll up to 5s
       └─ emit hookSpecificOutput.additionalContext
```

## Per-project scoping

Boot context and replay PID files live in `hooks/` and are keyed by a short
md5 of the hook input's `cwd`:

- `.boot-context-<hash>` — the pending boot summary
- `.replay-pid-<hash>` — PID of the running replay, used by the inject hook to
  decide whether to poll

Without the hash, project A's replay output would leak into project B's next
session. Both hooks must compute the hash the same way (`printf '%s' "$CWD" |
md5 | head -c 8`).

## Dependencies

- `@anthropic-ai/claude-agent-sdk` installed globally at
  `/opt/homebrew/lib/node_modules/` — `replay.mjs` imports `sdk.mjs` directly.
- `jq` — hook input parsing.
- `python3` — `auto-save-stop.sh` uses it to parse the JSONL transcript.

## auto-save-stop.sh

Counts user messages in the transcript, skipping `<command-message>` entries.
Every `SAVE_INTERVAL` (30) it returns `{"decision":"block", "reason":"..."}`
with instructions to write to `~/.claude/projects/*/memory/`. The `stop_hook_active`
guard prevents infinite loops — once Claude saves and tries to stop again, the
hook lets it through. State lives in `$HOME/.claude/hook_state/`:

- `<session-id>_last_save` — last exchange count at which a save fired
- `hook.log` — rolling log of exchanges seen

