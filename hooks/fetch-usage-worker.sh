#!/bin/sh
# Memory.Pack: refresh the per-model ("scoped") usage-window cache.
#
# Detached worker for fetch-usage.sh — never invoked directly by CC. Split out
# so it can be driven synchronously by tests (tests/test_fetch_usage.sh), the
# same launcher/worker separation session-end.sh uses for replay.mjs.
#
# Claude Code's statusline stdin carries only the COMBINED five_hour/seven_day
# windows. The per-model weekly windows (e.g. "Fable") live nowhere in the
# harness — the only source is Anthropic's OAuth usage endpoint, whose newer
# `limits[]` array carries an entry per window; the per-model ones are exactly
# those with a `scope.model.display_name`. Filtering on that presence (rather
# than on `kind == "weekly_scoped"`, or on the literal string "Fable") is what
# keeps a model rename from silently emptying the statusline segment.
#
# ACTIVE ACCOUNT ONLY. We read the token Claude Code itself owns and keeps
# fresh, so there is deliberately no refresh-token grant, no invalid_grant
# quarantine, and no 401-retry: an expired token just means we skip this tick
# and the next Stop tries again.
#
# Cache format (one file, atomic replace):
#     <fetch_epoch>
#     <pct> <resets_epoch> <display name>      ...one line per scoped window
# Name is LAST so a plain POSIX `read pct reset name` slurps display names that
# contain spaces. The leading stamp line is load-bearing: it is what the TTL
# gate compares against, and it lands even when the account has ZERO scoped
# windows — otherwise such an account would re-fetch on every single turn.
#
# Exit codes follow the engine convention: 0 ok, 2 benign no-op (no token,
# network down, response shape changed). On ANY failure the existing cache is
# left untouched — a stale percentage still beats a blank one, and
# statusline-command.sh drops the segment entirely once it passes 24h.
set -u

CACHE="$HOME/.claude/hook_state/usage_scoped"
URL="https://api.anthropic.com/api/oauth/usage"
BETA="oauth-2025-04-20"

# --- Credentials -----------------------------------------------------------
# macOS keeps them in the Keychain; Linux/WSL in plaintext. A Keychain miss
# (errSecItemNotFound, rc 44) falls through to the file rather than failing, so
# one code path serves both. `security` is looked up on PATH, never by absolute
# path — tests shadow it with a stub, and an absolute path would silently read
# the developer's REAL live token during a test run.
creds=""
if command -v security >/dev/null 2>&1; then
    creds=$(security find-generic-password -s "Claude Code-credentials" \
                     -a "$(id -un)" -w 2>/dev/null) || creds=""
fi
[ -n "$creds" ] || creds=$(cat "$HOME/.claude/.credentials.json" 2>/dev/null) || creds=""
[ -n "$creds" ] || exit 2

access=$(printf '%s' "$creds" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
sys.stdout.write((d.get("claudeAiOauth") or {}).get("accessToken") or "")
' 2>/dev/null) || exit 2
[ -n "$access" ] || exit 2

# --- Fetch -----------------------------------------------------------------
# The token rides a curl CONFIG FILE on stdin, never argv: `-H "Authorization:
# Bearer $tok"` would publish a live OAuth token to `ps aux` for every local
# process for the lifetime of the request. (claude-swap avoids this for free by
# using urllib; we use curl because it is stubbable via PATH in tests.)
resp=$(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\nheader = "anthropic-beta: %s"\nsilent\nfail\nmax-time = 10\n' \
        "$URL" "$access" "$BETA" | curl --config -) || exit 2
[ -n "$resp" ] || exit 2

# --- Parse + atomic replace ------------------------------------------------
# python3 (not jq) because ISO-8601 with fractional seconds AND a numeric offset
# — "2026-07-16T00:59:59.550694+00:00" — is exactly what jq's fromdateiso8601
# refuses, and the sed/awk surgery to feed it is the kind of quantifier trick
# that already bit this repo on BSD. python3 is a hard engine dependency
# (index/*.py) so this costs nothing.
#
# A missing or non-list `limits` exits non-zero → the cache is NOT replaced.
# That is the schema-drift path: render last-good, and let the 24h drop in
# statusline-command.sh retire it if the drift is permanent.
mkdir -p "$(dirname "$CACHE")" 2>/dev/null || exit 2
tmp="$CACHE.tmp.$$"
if printf '%s' "$resp" | python3 -c '
import sys, json, time
from datetime import datetime

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
limits = d.get("limits") if isinstance(d, dict) else None
if not isinstance(limits, list):
    sys.exit(1)

rows = []
for lim in limits:
    if not isinstance(lim, dict):
        continue
    scope = lim.get("scope")
    model = scope.get("model") if isinstance(scope, dict) else None
    name = model.get("display_name") if isinstance(model, dict) else None
    pct = lim.get("percent")
    # bool is an int subclass — reject it before the isinstance check passes.
    if not name or isinstance(pct, bool) or not isinstance(pct, (int, float)):
        continue
    # Collapse any interior whitespace: a newline in a display name would tear
    # the one-record-per-line format the shell reader depends on.
    name = " ".join(str(name).split())
    epoch = 0
    resets = lim.get("resets_at")
    if resets:
        try:
            epoch = int(datetime.fromisoformat(str(resets).replace("Z", "+00:00")).timestamp())
        except Exception:
            epoch = 0   # unparseable → sentinel; statusline hides the countdown
    rows.append("%.0f %d %s" % (pct, epoch, name))

sys.stdout.write("\n".join([str(int(time.time()))] + rows) + "\n")
' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$CACHE"
else
    rm -f "$tmp"
    exit 2
fi
