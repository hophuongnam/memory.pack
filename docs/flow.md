# Memory Pack Flow

## Session lifecycle

```mermaid
sequenceDiagram
    participant S1 as Session N (ending)
    participant SE as session-end.sh
    participant R as replay.mjs (nohup)
    participant F as Filesystem
    participant S2 as Session N+1 (starting)
    participant BI as boot-inject.sh

    Note over S1: Session ends

    S1->>SE: SessionEnd event<br/>(session_id, transcript_path, cwd)
    SE->>SE: Count user turns in transcript
    alt turns <= 5
        SE--xSE: exit (trivial session)
    end
    SE->>SE: hash cwd → PROJECT_HASH
    SE->>F: rm stale .boot-context-&lt;hash&gt; / .replay-pid-&lt;hash&gt;
    SE->>R: nohup detach (exits in <1.5s)
    R->>F: Write PID to .replay-pid-&lt;hash&gt;

    Note over R: Runs after session closes

    R->>R: getSessionMessages() via Agent SDK
    R->>R: Sonnet 4.6 summarizes<br/>(TITLE, SUMMARY, TODO, DECISIONS)
    R->>F: stdout → .boot-context-&lt;hash&gt;.tmp
    R->>F: atomic mv → .boot-context-&lt;hash&gt;
    R->>F: rm .replay-pid-&lt;hash&gt;

    Note over S2: Next session starts (same cwd → same hash)

    S2->>BI: SessionStart event
    BI->>BI: hash cwd → PROJECT_HASH
    alt .boot-context-&lt;hash&gt; exists
        BI->>F: read & delete
        BI->>S2: inject "[Boot context loaded…]" + body
    else replay still running
        BI->>S2: inject "[Previous session replay is still processing.]"
    else
        BI->>S2: inject "[No boot context available from previous session.]"
    end

    Note over S2: User submits first prompt

    S2->>BI: UserPromptSubmit event (fallback)
    alt boot context not ready & replay running
        BI->>BI: poll up to 5s
    end
    BI->>S2: inject context if now available
```

## Component overview

```mermaid
flowchart TB
    subgraph settings["~/.claude/settings.json"]
        CFG[absolute-path hook config]
    end

    subgraph hooks["Memory.Pack/hooks/"]
        SE[session-end.sh<br/><i>SessionEnd</i>]
        BI[boot-inject.sh<br/><i>SessionStart + UserPromptSubmit</i>]
        AS[auto-save-stop.sh<br/><i>Stop</i>]
    end

    subgraph replay["Replay Agent (detached)"]
        RM[replay.mjs<br/><i>Agent SDK + Sonnet 4.6</i>]
    end

    subgraph storage["Filesystem (per-project, hash of cwd)"]
        BC[.boot-context-&lt;hash&gt;]
        PID[.replay-pid-&lt;hash&gt;]
    end

    subgraph savestate["$HOME/.claude/hook_state/"]
        LS[&lt;session-id&gt;_last_save]
        LOG[hook.log]
    end

    CFG --> SE
    CFG --> BI
    CFG --> AS
    SE -->|nohup| RM
    RM -->|stdout → .tmp → mv| BC
    RM -->|write/remove| PID
    BI -->|read & delete| BC
    BI -->|check alive| PID
    AS -->|track exchanges| LS
    AS -->|append| LOG
```

## auto-save Stop loop

```mermaid
flowchart LR
    Stop[Stop event] --> CountMsg[Count user msgs in transcript]
    CountMsg --> Compare{since_last >= 30?}
    Compare -->|no| OK[return empty JSON]
    Compare -->|yes| Block["decision: block<br/>reason: save to internal memory"]
    Block --> Save[Claude saves to ~/.claude/projects/.../memory/]
    Save --> Stop2[Claude tries to stop again<br/>stop_hook_active=true]
    Stop2 --> Pass[hook lets it through]
```

## Wiring

Hooks are invoked by absolute path from `~/.claude/settings.json`, so the
`Memory.Pack/hooks/` directory is the single source of truth — there are no
per-project symlinks. The only per-project bit of state is the `cwd` hash
that scopes the boot-context and PID files inside `hooks/`.
