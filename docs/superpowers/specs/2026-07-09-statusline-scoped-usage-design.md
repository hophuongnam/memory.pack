# Per-model ("Fable") usage segment on the statusline

**Status:** approved 2026-07-09

## Problem

Claude Code's statusline stdin carries only the *combined* `rate_limits.five_hour`
and `rate_limits.seven_day` windows. It has no per-model breakdown, so the
weekly Fable window — the one that actually gates Fable work — is invisible.

`claude-swap` (`github.com/realiti4/claude-swap`) surfaces it. Its mechanism,
verified three ways (source, its test fixtures, its live on-disk cache):

1. Read the OAuth access token from the macOS Keychain item
   `Claude Code-credentials` (field `claudeAiOauth.accessToken`); on Linux from
   plaintext `~/.claude/.credentials.json`.
2. `GET https://api.anthropic.com/api/oauth/usage` with
   `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`.
3. The response carries the legacy `five_hour`/`seven_day` keys **plus** a newer
   `limits[]` array. Per-model windows are the entries whose
   `scope.model.display_name` is set:

   ```json
   {"kind": "weekly_scoped", "group": "weekly", "percent": 100,
    "severity": "critical", "resets_at": "2026-07-16T00:59:59.550694+00:00",
    "scope": {"model": {"id": null, "display_name": "Fable"}}, "is_active": true}
   ```

   `session` and `weekly_all` entries carry `scope: null` and drop out.

We build our own rather than reading cswap's cache: that cache is a third-party
private file at `schemaVersion 1`, and it only refreshes while cswap's poller is
running.

## Non-goals

- **No token refresh.** cswap refreshes because it manages *inactive* accounts.
  We only ever read the *active* account's token, which Claude Code owns and
  keeps fresh. Expired → skip this tick. This deletes the `invalid_grant`
  quarantine, the 401-retry path, and the persist callback.
- **No multi-account support.** The live keychain token *is* the active account.
- **No backoff.** One attempt per turn is the natural ceiling; cswap's own
  source notes the 429 burst rule needs ~5 rapid requests to trip.
- **We do not re-derive 5h/7d from the endpoint.** They arrive free on stdin.

## Architecture

```
Stop ──▶ hooks/fetch-usage.sh
             │ cache younger than TTL (120s)? exit 0
             │ else nohup ( security │ curl --config - │ python3 ) &
             ▼
    ~/.claude/hook_state/usage_scoped
             ▲
             │ plain `read`, no jq, no network
    statusline-command.sh  (every render)
```

### Cache format

One file. Line 1 is the fetch epoch; each remaining line is one scoped window,
**name last** so a POSIX `read` slurps display names containing spaces.

```
1783035600
2 1783040399 Fable
```

Consumed forklessly:

```sh
{ read -r fetched
  while read -r pct reset name; do ...; done
} < "$cache"
```

The leading stamp line is what makes the TTL gate work for an account with
*zero* scoped windows — the stamp still lands, so we don't re-fetch every turn.
Staleness is an integer compare against field 1, so no `stat(1)` and no
BSD/GNU portability trap.

### Token never enters argv

`curl -H "Authorization: Bearer $tok"` exposes a live OAuth token in `ps aux`
to every local process. We pipe a config file to `curl --config -` on stdin
instead. (cswap gets this free via `urllib`; we use `curl` because it is
stubbable via `PATH` in tests, so we pay for that choice here.)

### Render

Scoped segments append to line 2 after `7d`, using `format_pct` with a new
`compact` parameter (7th positional):

| mode | cols | scoped segment |
|---|---|---|
| full | > 80 | bar (width 10) + live `↻` countdown |
| medium | 56–80 | percentage only |
| narrow | ≤ 55 | percentage only |

Medium is the squeeze: `ctx`+`5h`+`7d` at bar width 6 already eat ~66 of 80
columns. Compact-below-full fits every mode and never hides a maxed window —
`format_pct` currently forces bar width 6 in medium, which the new parameter
overrides.

The reset countdown is always recomputed live from the stored `resets_at` epoch,
so only the *percentage* ever goes stale.

## Error handling

| condition | behavior |
|---|---|
| no token / no keychain item | exit 2 (benign no-op), cache untouched |
| `curl` non-zero, malformed JSON, changed shape | exit 2, **cache untouched** (last-good survives) |
| successful fetch, zero scoped windows | write stamp-only cache (suppresses re-fetch storm) |
| cache stale but < 24h | render normally |
| cache ≥ 24h old | **drop the segment** rather than render a stale number |

Writes are atomic (`tmp` + `mv`).

## Surface changes

- new `hooks/fetch-usage.sh` (launcher: TTL gate + detach) and
  `hooks/fetch-usage-worker.sh` (worker: token → curl → parse → atomic write).
  Split so the worker is synchronously testable instead of racing an orphaned
  child — the same launcher/worker separation `session-end.sh` uses for
  `replay.mjs`.
- new `ICON_SCOPED` in `hooks/statusline-icons.sh` — codepoint verified against
  the real font with fontTools (the glyph comments have lied twice: see
  `feedback_verify_nerd_glyph_codepoints_against_font`)
- `format_pct` in `statusline-command.sh` gains a 7th positional `compact` arg
- one new `Stop` entry in `install/hooks.manifest.json` (13 → 14 registrations)
- new `tests/test_fetch_usage.sh`; scoped cases added to
  `tests/test_statusline_render.sh` (24 → 25 suites)
- `CLAUDE.md` counts updated

The cache lives in `~/.claude/hook_state/`, already outside the repo, so
invariant #5 (runtime state is never packaged) holds without a `.gitignore`
change. The name `usage_scoped` deliberately matches neither `*_last_save` nor
`*_turns`, the two globs `auto-save-stop.sh` garbage-collects.

## Testing

`security` and `curl` are both stubbed on `PATH` — no real keychain read and no
real network in the suite. Behavioral-subprocess idiom (`test_install.sh`
style): run the real hook against a fake response and assert the cache bytes.

Mutation checks on every value-critical path — verified by breaking each one
and watching the suite go red:

- TTL gate (fresh cache must not spawn a fetch)
- dash int-guard on the stamp (the one fatal-arith surface)
- token-into-argv
- clobber-on-parse-failure
- 24h hard-drop boundary
- `compact` arg (medium must not render a bar)
- epoch-0 sentinel (hide ↻, don't print "now")
- torn-row skip and empty-name guard

## Known risk

This bakes a dependency on an **undocumented endpoint** into a hook that runs
every turn. When Anthropic changes `limits[]`, the fetch parses nothing, the
cache is not clobbered, and 24h later the segment silently disappears. That is
the safe direction, but it fails *quietly* — precisely this engine's stated
worst failure class. The tests pin our parser, not their schema.
