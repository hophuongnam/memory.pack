#!/bin/bash
# ORPHAN BACKSTOP — SessionStart hook: replay sessions whose SessionEnd never fired.
#
# The gap this closes: the detached replay is launched ONLY by session-end.sh,
# and CC's SessionEnd does not fire on abnormal termination (crash, force-quit,
# terminal closed, power loss). A crashed session's transcript was never
# replayed — no boot context, no PENDING_MEMORIES mining — so the next session
# booted blind about it. Silent-amnesia class (idea credit: acdesigntech/
# memory-project's session_start_backstop; liveness redesigned, see below).
#
# Shape: hook mode parses stdin, then detaches --sweep and exits immediately —
# the 5s SessionStart budget is never spent on scanning. The sweep walks ALL
# ~/.claude/projects/*/*.jsonl (a transcript lives under the project dir of its
# FIRST entry, not necessarily this project's) and, for each project's newest
# eligible transcript, synthesizes SessionEnd stdin and pipes it into the REAL
# session-end.sh — every existing gate (trivial-skip, substance rescue, slug
# resolver, carry-forward, detached launcher, error banners) is reused, not
# duplicated. When the replayed boot context lands, boot-catchup.sh injects it
# into the very session that triggered the sweep, mid-turn.
#
# Eligibility (ALL must hold — every filter fails toward "not an orphan"):
#   post-baseline — mtime newer than hook_state/orphan-baseline. The baseline
#     self-initializes on first run: transcripts predating the feature are
#     exempt FOREVER (no retroactive quota burn, no stale boot-context
#     regressions on historical sessions).
#   in-horizon   — modified within MP_ORPHAN_HORIZON_MIN (default 3 days);
#     older crashes have lost their continuity value.
#   quiet        — untouched for MP_ORPHAN_QUIET_MIN (default 30 min). This is
#     the PRIMARY liveness signal: CC does NOT hold the transcript fd open
#     between writes (verified 2026-07-27: lsof on a live session's own
#     transcript exits 1), so lsof cannot answer "is this session dead" — it
#     runs only as an opportunistic extra veto below. Quiet fails SAFE: a
#     live-but-silent session is merely swept later; a crashed one is quiet
#     forever. A >quiet-window single tool call can fake death — bounded harm
#     (duplicate replay; the real SessionEnd re-handles and overwrites).
#   unstamped    — no hook_state/<sid>_end_handled ledger entry (session-end.sh
#     stamps every handled end; the stamp doubles as the sweep's atomic claim).
#   interactive  — .boot-marker-<sid> exists in the hooks dir: the session
#     provably BOOTED through boot-inject. Hook-less SDK children — replay.mjs
#     runs both passes with settingSources: [], so no hook ever fires for
#     them — write transcripts into the SAME project dir but get no marker and
#     no stamp: quiet + unstamped + cwd-verified, they satisfied every other
#     filter, and the sweep re-replayed the replay's own children 30 minutes
#     later, each garbage replay spawning two more marker-less children
#     (async replay-of-replay storm, observed 2026-07-28 — the asynchronous
#     twin of the 2026-07-25 settingSources loop). Markers survive crashes
#     (session-end.sh removes them only on a HANDLED end) and boot-inject/
#     session-end GC them at 3 days, matching the horizon, so a real crash
#     orphan keeps its marker for exactly as long as it stays sweepable.
#   not current  — never the session that is starting right now.
#   not superseded — no NEWER stamped sibling in the same project dir: its boot
#     context already supersedes the orphan's; replaying the orphan would
#     REGRESS continuity to the older session.
#   no skip sentinel — a live .skip-replay-<hash> for the orphan's project
#     means the user opted that project out; honor it but do NOT consume it
#     (it belongs to the running session's own SessionEnd).
#   verified cwd — the orphan's project key is recovered from cwd values inside
#     the transcript and accepted only if _mp_resolve_project_key's answer
#     slugifies back to the transcript's parent-dir slug (invariant #4: never
#     mis-file another project's boot context). No verified cwd → skip.
#
# Two passes: pass 1 catches orphans already quiet (user restarted after a
# pause); pass 2, after the quiet window elapses, catches the crash-then-
# immediate-restart case whose transcript is too fresh at SessionStart. The
# claim stamp makes overlapping sweeps (concurrent session starts, both
# passes) launch each orphan at most once.
#
# Never replay a replay (loop-breaker belt, same class as session-end.sh):
[ -n "$MP_REPLAY_CHILD" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_lib.sh" || { echo "memory-pack: cannot source $SCRIPT_DIR/_lib.sh" >&2; exit 1; }
SELF="$SCRIPT_DIR/$(basename "$0")"

# $HOME/.claude is DELIBERATE here, not an oversight: do NOT rewrite it to
# ${CLAUDE_CONFIG_DIR:-…}. This sweep scans the SHARED projects/ transcript tree,
# so its <sid>_end_handled stamps and its baseline must be shared too. Split them
# per config dir and each account re-scans the other account's transcripts with
# none of its own stamps: the correctness gate holds (the .boot-marker-<sid> test
# below lives in the repo, shared under any config dir) but the cost guard dies
# and orphan-baseline re-arms per account. Only genuinely per-account runtime —
# the OAuth usage cache in fetch-usage-worker.sh — follows CLAUDE_CONFIG_DIR.
# See project_multi_account_config_dir in the project memory store.
STATE_DIR="$HOME/.claude/hook_state"
BASELINE="$STATE_DIR/orphan-baseline"

if [ "${1:-}" != "--sweep" ]; then
  # ---- hook mode: parse stdin, gate on source, detach the sweep ----
  INPUT=$(cat)
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // .sessionId // empty')
  SOURCE=$(echo "$INPUT" | jq -r '.source // empty')
  # Sweep only on a genuinely fresh session. resume/clear/compact re-fire
  # SessionStart for an already-running conversation; an absent source (older
  # CC) is treated as startup so the net still exists there.
  if [ -n "$SOURCE" ] && [ "$SOURCE" != "startup" ]; then
    exit 0
  fi
  export MP_CURRENT_SID="$SESSION_ID"
  if [ "${MP_ORPHAN_SYNC:-0}" = "1" ]; then
    exec bash "$SELF" --sweep
  fi
  nohup bash "$SELF" --sweep </dev/null >/dev/null 2>&1 &
  disown
  exit 0
fi

# ---- sweep mode ----
mkdir -p "$STATE_DIR" 2>/dev/null
if [ ! -f "$BASELINE" ]; then
  # Self-init (works on a plain `git pull`, no reinstall needed): everything
  # already on disk is pre-feature history, exempt forever.
  : > "$BASELINE"
  exit 0
fi

QUIET_MIN="${MP_ORPHAN_QUIET_MIN:-30}"
case "$QUIET_MIN" in ''|*[!0-9]*) QUIET_MIN=30 ;; esac
HORIZON_MIN="${MP_ORPHAN_HORIZON_MIN:-4320}"
case "$HORIZON_MIN" in ''|*[!0-9]*) HORIZON_MIN=4320 ;; esac
MAXN="${MP_ORPHAN_MAX:-2}"
case "$MAXN" in ''|*[!0-9]*) MAXN=2 ;; esac
PASS2="${MP_ORPHAN_PASS2:-1}"
PASS2_SLEEP="${MP_ORPHAN_PASS2_SLEEP:-$((QUIET_MIN * 60 + 60))}"
case "$PASS2_SLEEP" in ''|*[!0-9]*) PASS2_SLEEP=$((QUIET_MIN * 60 + 60)) ;; esac

LAUNCHED=0

do_pass() {
  CANDIDATES=""
  for pdir in "$HOME/.claude/projects"/*/; do
    [ -d "$pdir" ] || continue
    best=""
    for t in $(find "$pdir" -maxdepth 1 -name '*.jsonl' -newer "$BASELINE" -mmin +"$QUIET_MIN" -mmin -"$HORIZON_MIN" 2>/dev/null); do
      sid=$(basename "$t" .jsonl)
      [ -n "${MP_CURRENT_SID:-}" ] && [ "$sid" = "$MP_CURRENT_SID" ] && continue
      # Cost guard, not the correctness gate (the noclobber claim below is
      # behaviorally equivalent for stamped sids — mutation-verified): this
      # filter exists so a handled transcript never reaches the full-file jq
      # cwd extraction, which on a 100MB transcript is the sweep's only
      # expensive step. Pinned structurally by test D4.
      [ -f "$STATE_DIR/${sid}_end_handled" ] && continue
      # Interactive-evidence gate (see header): no boot marker → the session
      # never booted through our hooks → it is an SDK child (replay pass 1/2,
      # promotion agents), not a crashed session. Replaying it is the async
      # replay-of-replay loop. Fails toward "not an orphan".
      [ -f "$SCRIPT_DIR/.boot-marker-$sid" ] || continue
      # Opportunistic veto only — see header: lsof CANNOT prove death, but an
      # open fd (a fd-holding future CC, a tail -f) does prove "don't touch".
      if command -v lsof >/dev/null 2>&1 && lsof -- "$t" >/dev/null 2>&1; then
        continue
      fi
      if [ -z "$best" ] || [ "$t" -nt "$best" ]; then
        best="$t"
      fi
    done
    [ -z "$best" ] && continue
    superseded=0
    for s in "$pdir"*.jsonl; do
      [ -f "$s" ] || continue
      ssid=$(basename "$s" .jsonl)
      [ -f "$STATE_DIR/${ssid}_end_handled" ] || continue
      if [ "$s" -nt "$best" ]; then
        superseded=1
        break
      fi
    done
    [ "$superseded" = "1" ] && continue
    CANDIDATES="$CANDIDATES $best"
  done

  [ -z "$CANDIDATES" ] && return 0

  # Newest first across projects: continuity value decays with age, so under
  # the cap the most recent crash wins.
  for t in $(ls -t $CANDIDATES 2>/dev/null); do
    [ "$LAUNCHED" -ge "$MAXN" ] && break
    sid=$(basename "$t" .jsonl)
    slug=$(basename "$(dirname "$t")")

    # Recover the project key from cwds recorded inside the transcript and
    # accept only a slug-verified resolution (invariant #4). A cwd outside
    # the project (user cd'd away) resolves to itself and fails the check.
    cwd=""
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      key=$(_mp_resolve_project_key "$t" "$c")
      if [ "$(printf '%s' "$key" | sed 's|[/.]|-|g')" = "$slug" ]; then
        cwd="$key"
        break
      fi
    done <<MP_CWDS
$(jq -cR 'fromjson? // empty' "$t" 2>/dev/null | jq -sr '[.[] | .cwd? // empty] | map(select(. != "")) | unique | .[]' 2>/dev/null)
MP_CWDS
    [ -z "$cwd" ] && continue

    PROJECT_HASH=$(printf '%s' "$cwd" | _mp_hash) || continue
    [ -f "$SCRIPT_DIR/.skip-replay-$PROJECT_HASH" ] && continue

    # Atomic claim (noclobber): concurrent sweeps — another session starting,
    # or our own pass 2 — must launch each orphan at most once. The claim IS
    # the <sid>_end_handled stamp; session-end.sh re-stamping it is harmless.
    ( set -C; : > "$STATE_DIR/${sid}_end_handled" ) 2>/dev/null || continue

    jq -n --arg sid "$sid" --arg t "$t" --arg cwd "$cwd" \
      '{hook_event_name: "SessionEnd", session_id: $sid, transcript_path: $t, cwd: $cwd}' \
      | bash "$SCRIPT_DIR/session-end.sh" >/dev/null 2>&1
    LAUNCHED=$((LAUNCHED + 1))
  done
}

do_pass
if [ "$PASS2" = "1" ] && [ "$LAUNCHED" -lt "$MAXN" ]; then
  sleep "$PASS2_SLEEP"
  do_pass
fi
exit 0
