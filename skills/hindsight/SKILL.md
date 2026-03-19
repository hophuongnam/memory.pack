---
name: hindsight
description: |
  Persistent long-term memory via self-hosted Hindsight server. Stores and retrieves project knowledge across sessions.
  ALWAYS retain after completing meaningful work.
  Use this skill when: before non-trivial tasks, after completing work,
  learning conventions, fixing bugs, making architecture decisions, discovering preferences,
  managing mental models, creating directives, browsing memories, or checking async operations.
  Trigger phrases: remember, recall, memory, context, what did we do, store, retain, reflect, mental model, directive.
---

# Hindsight Memory Skill

Hindsight is the **persistent long-term memory** system. Use it proactively — it is vital for continuity across sessions.

## Prerequisites

Requires the `hindsight` MCP server configured in the project's `.mcp.json`.

## Bank Naming Convention

Use the current project's directory name (lowercase, hyphenated) as `bank_id`.
Derive from the working directory — e.g. `/Users/namhp/Resilio.Sync/MyProject` → `myproject`.

## Core Operations

### retain — Store knowledge

Store a fact, decision, or outcome to long-term memory.

| Param | Required | Description |
|-------|----------|-------------|
| `content` | Yes | The information to store — be specific |
| `bank_id` | No | Target bank (defaults to session bank) |
| `context` | No | Category context (default: `"general"`) |
| `tags` | No | List of tags for filtering (e.g. `["project:alpha", "bug"]`) |
| `document_id` | No | Group under a document container |
| `metadata` | No | Key-value pairs for extra context |
| `timestamp` | No | Override timestamp (ISO format) |

### recall — Retrieve facts

Search memories by relevance. Returns raw matching facts — use for **"what did I say about X?"**

| Param | Required | Description |
|-------|----------|-------------|
| `query` | Yes | What to search for |
| `bank_id` | No | Target bank |
| `budget` | No | Search depth: `low`, `mid`, `high` (default: `high`) |
| `max_tokens` | No | Max response tokens (default: 4096) |
| `tags` | No | Filter by tags |
| `tags_match` | No | `any` (default) or `all` — how to match multiple tags |
| `types` | No | Filter by memory type: `world`, `experience`, `opinion` |

### reflect — Synthesize insights

Reasons across memories to form a synthesized answer — use for **"what should I do about X?"**

| Param | Required | Description |
|-------|----------|-------------|
| `query` | Yes | The question to reflect on |
| `bank_id` | No | Target bank |
| `context` | No | Why this reflection is needed |
| `budget` | No | Search depth: `low` (default), `mid`, `high` |
| `max_tokens` | No | Max response tokens (default: 4096) |
| `tags` | No | Filter by tags |
| `tags_match` | No | `any` (default) or `all` |
| `response_schema` | No | JSON schema for structured output |

### recall vs reflect

| | **recall** | **reflect** |
|---|---|---|
| Purpose | Fact lookup | Reasoned analysis |
| Speed | Fast | Slower |
| Output | Raw matching memories | Synthesized answer |
| Use when | "What did I say about X?" | "What patterns emerge from X?" |
| Budget default | `high` | `low` |

## Mental Models

**Living documents** that stay current by periodically re-running a source query through `reflect`. Use them for maintained summaries, preference profiles, or synthesized knowledge that should auto-update.

- **`list_mental_models`** — List all models. Optional: `tags`, `bank_id`
- **`get_mental_model`** — Get full model content. Params: `mental_model_id`
- **`create_mental_model`** — Create a new model. Params: `name`, `source_query`. Optional: `mental_model_id`, `tags`, `max_tokens` (256-8192), `trigger_refresh_after_consolidation`
- **`update_mental_model`** — Update metadata. Params: `mental_model_id`. Optional: `name`, `source_query`, `max_tokens`, `tags`, `trigger_refresh_after_consolidation`
- **`delete_mental_model`** — Permanently remove. Params: `mental_model_id`
- **`refresh_mental_model`** — Re-run source query to update content. Params: `mental_model_id`

**Examples of useful mental models:**
- `name="Coding Conventions"`, `source_query="What coding patterns, conventions, and standards does this project follow?"`
- `name="Infrastructure Overview"`, `source_query="What servers, services, and infrastructure does this project use?"`
- `name="User Preferences"`, `source_query="What are the user's preferences for how I should work?"`

Set `trigger_refresh_after_consolidation=true` to auto-refresh when memories are consolidated.

## Directives

**Instructions that guide how the memory engine processes queries and generates reflections.** They shape `reflect` behavior and memory organization — like system prompts for the memory engine.

- **`list_directives`** — List directives. Optional: `tags`, `active_only` (default: true)
- **`create_directive`** — Create new directive. Params: `name`, `content`. Optional: `priority` (higher = more important), `is_active`, `tags`
- **`delete_directive`** — Remove directive. Params: `directive_id`

## Documents

**Containers for grouping related memories.** When retaining with a `document_id`, memories are grouped under that document (e.g. a conversation transcript, meeting notes).

- **`list_documents`** — Browse documents. Optional: `q` (search), `limit`
- **`get_document`** — Get document metadata and linked memories. Params: `document_id`
- **`delete_document`** — Delete document **and all its memories**. Params: `document_id`

## Tags

Organize and filter across memories, directives, and mental models. Use namespaced tags like `project:alpha`, `type:bug`, `server:gpu-node`.

- **`list_tags`** — List all tags in use. Optional: `q` (pattern filter, e.g. `project:*`), `limit`

## Memory Browsing

- **`list_memories`** — Browse/search memories directly (no relevance ranking). Optional: `type` (`world`, `experience`, `opinion`), `q` (text search), `limit`, `offset`
- **`get_memory`** — Get full memory by ID. Params: `memory_id`
- **`delete_memory`** — Permanently remove. Params: `memory_id`

## Bank Management

- **`list_banks`** — List all banks
- **`create_bank`** — Create bank. Params: `bank_id`. Optional: `name`, `mission`
- **`get_bank`** / **`get_bank_stats`** — Bank profile and statistics
- **`update_bank`** — Update bank metadata. Optional: `name`, `mission`
- **`delete_bank`** — **Permanently** delete bank and all data
- **`clear_memories`** — Clear memories without deleting bank. Optional: `type` filter

## Async Operations

Background tasks (retain processing, mental model refresh) are tracked as operations.

- **`list_operations`** — List tasks. Optional: `status` (`pending`, `running`, `completed`, `failed`, `cancelled`), `limit`
- **`get_operation`** — Check progress. Params: `operation_id`
- **`cancel_operation`** — Cancel pending/running task. Params: `operation_id`

## Session Continuity

Boot context arrives **automatically** via hooks — no need to manually recall at session start.

- A **"handoff" mental model** exists as a living doc of active work, auto-refreshed each session close
- Session-close retention is **deterministic** (replay agent handles it via Hindsight HTTP API)
- Mid-session retain is still encouraged but not load-bearing
- Read handoff with `get_mental_model("handoff")`

## Proactive Usage — MANDATORY

### After Completing Work
- **Retain** outcomes: what was done, what worked, what failed, key decisions made.

### Before Starting Non-Trivial Tasks
- **Recall** to check for past context, conventions, gotchas, or prior attempts.

## What to Retain

- Project conventions and coding standards
- Procedure outcomes — what worked or failed and why
- Bug solutions, workarounds, configuration fixes
- Architecture decisions and rationale
- User preferences
- Tool/version requirements
- Infrastructure changes (server configs, deployments, service updates)

Be specific: store `"npm test requires --experimental-vm-modules flag"` not `"tests need a flag"`.

## Best Practices

1. **Recall first** — check for context before starting work
2. **Store immediately** — retain learnings as they happen, don't wait
3. **Be specific** — include commands, versions, error messages
4. **Include outcomes** — store what worked AND what failed
5. **One fact per retain** — keep each retain focused on a single piece of knowledge
6. **Use tags** — tag memories for easier filtering later (e.g. `server:gpu-node`, `project:nexuslit`)
7. **Use reflect for analysis** — when you need synthesis, not just facts
8. **Create mental models** — for knowledge that should stay up-to-date across sessions
