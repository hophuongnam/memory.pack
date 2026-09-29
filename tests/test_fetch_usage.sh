#!/bin/bash
# TDD: hooks/fetch-usage.sh (launcher) + hooks/fetch-usage-worker.sh (worker).
#
# Stop hook that refreshes the per-model ("scoped") usage windows — the ones
# CC's statusline stdin never carries. Anthropic's OAuth usage endpoint returns
# a `limits[]` array whose per-model entries carry scope.model.display_name
# (e.g. "Fable"); statusline-command.sh renders them from an on-disk cache.
#
# Split mirrors session-end.sh → replay.mjs: the LAUNCHER TTL-gates and detaches;
# the WORKER does token → curl → parse → atomic write. Detaching inside one
# script would make every assertion race an orphaned child; splitting lets the
# worker be driven synchronously and the gate be tested with the worker stubbed
# (the test_boot_catchup Layer-1/Layer-2 idiom).
#
# NOTHING here may touch the real Keychain or the real network: `security` and
# `curl` are both shadowed by stubs on PATH. Each stub records that it ran, so a
# real binary leaking through (absolute path in the hook, PATH not inherited
# across the detach) fails the suite loudly instead of silently hitting
# api.anthropic.com with a live OAuth token.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER="$HERE/../hooks/fetch-usage.sh"
WORKER="$HERE/../hooks/fetch-usage-worker.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[ -f "$LAUNCHER" ] || { echo "FAIL  hooks/fetch-usage.sh missing"; exit 1; }
[ -f "$WORKER" ]   || { echo "FAIL  hooks/fetch-usage-worker.sh missing"; exit 1; }
[ -x "$LAUNCHER" ] || bad "launcher must have +x mode"
[ -x "$WORKER" ]   || bad "worker must have +x mode"

SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT
export HOME="$SBX"
STATE="$HOME/.claude/hook_state"
CACHE="$STATE/usage_scoped"
mkdir -p "$STATE"

# ─── stubs: security + curl, shadowing the real binaries via PATH ─────────
mkdir -p "$SBX/bin"
cat > "$SBX/bin/security" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$SBX/security.argv"
[ -f "$SBX/security.out" ] || exit 44   # 44 = errSecItemNotFound, like the real tool
cat "$SBX/security.out"
EOF
cat > "$SBX/bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$SBX/curl.argv"
cat > "$SBX/curl.stdin"                 # \`curl --config -\` reads its config here
code=\$(cat "$SBX/curl.exit" 2>/dev/null || echo 0)
[ "\$code" = 0 ] || exit "\$code"
cat "$SBX/curl.out"
EOF
chmod +x "$SBX/bin/security" "$SBX/bin/curl"
export PATH="$SBX/bin:$PATH"

TOKEN="sk-ant-oat01-TESTTOKEN"
creds() { printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"rt","expiresAt":99}}' "$TOKEN"; }

# Expected epoch for the fixture's resets_at — computed, never hardcoded.
RESETS_ISO="2026-07-16T00:59:59.550694+00:00"
RESETS_EPOCH=$(python3 -c "
from datetime import datetime
print(int(datetime.fromisoformat('$RESETS_ISO').timestamp()))")

# limits[]: a session entry, a weekly_all entry (both scope:null → must drop),
# and one weekly_scoped entry carrying scope.model.display_name.
response() {
  cat <<EOF
{"five_hour":{"utilization":18},"seven_day":{"utilization":4},
 "limits":[
   {"kind":"session","group":"session","percent":18,"resets_at":null,"scope":null},
   {"kind":"weekly_all","group":"weekly","percent":4,"resets_at":null,"scope":null},
   {"kind":"weekly_scoped","group":"weekly","percent":${1:-2},"severity":"ok",
    "resets_at":"$RESETS_ISO",
    "scope":{"model":{"id":null,"display_name":"${2:-Fable}"},"surface":null},
    "is_active":true}
 ]}
EOF
}

reset_sbx() {
  rm -f "$CACHE" "$SBX"/curl.* "$SBX"/security.* "$SBX"/worker.ran
  printf '%s' "$(creds)" > "$SBX/security.out"
  response > "$SBX/curl.out"
}

now() { date +%s; }

# ══════════════════════════════════════════════════════════════════════════
# LAYER 1 — the launcher's TTL gate, with the worker STUBBED.
# Isolates "does it decide to fetch" from "does the fetch work".
# ══════════════════════════════════════════════════════════════════════════
mkdir -p "$SBX/hooks"
cp "$LAUNCHER" "$SBX/hooks/fetch-usage.sh"
cat > "$SBX/hooks/fetch-usage-worker.sh" <<EOF
#!/bin/sh
touch "$SBX/worker.ran"
EOF
chmod +x "$SBX/hooks/fetch-usage.sh" "$SBX/hooks/fetch-usage-worker.sh"
STUB_LAUNCHER="$SBX/hooks/fetch-usage.sh"

# The launcher detaches; give the orphan a bounded moment to touch its marker.
worker_ran() {
  n=0
  while [ $n -lt 200 ]; do [ -f "$SBX/worker.ran" ] && return 0; sleep 0.05; n=$((n+1)); done
  return 1
}

stop_stdin='{"session_id":"sid-1","hook_event_name":"Stop"}'

# L1 — no cache at all → must fetch
reset_sbx
echo "$stop_stdin" | sh "$STUB_LAUNCHER"
[ "$?" -eq 0 ] && ok "launcher exits 0 (no cache)" || bad "launcher exits 0 (no cache)"
worker_ran && ok "no cache → worker spawned" || bad "no cache → worker spawned"

# L2 — fresh cache (stamp = now) → must NOT fetch.  [TTL gate; mutation-pinned:
# delete the gate and this is the assertion that goes red]
reset_sbx
printf '%s\n2 %s Fable\n' "$(now)" "$RESETS_EPOCH" > "$CACHE"
echo "$stop_stdin" | sh "$STUB_LAUNCHER"
sleep 0.3
[ -f "$SBX/worker.ran" ] && bad "fresh cache → worker must NOT spawn" || ok "fresh cache → worker must NOT spawn"

# L3 — stale cache (stamp well past the 120s TTL) → must fetch
reset_sbx
printf '%s\n2 %s Fable\n' "$(( $(now) - 9999 ))" "$RESETS_EPOCH" > "$CACHE"
echo "$stop_stdin" | sh "$STUB_LAUNCHER"
worker_ran && ok "stale cache → worker spawned" || bad "stale cache → worker spawned"

# L4 — corrupt stamp must be treated as stale, and must NOT be fed to $(( )).
# Under dash a non-integer arithmetic operand is FATAL (see
# feedback_dash_arith_fatal_on_noninteger); bash merely warns. Run the launcher
# under real dash where the platform ships it, so the guard is proven, not assumed.
for stamp in "not-a-number" "1.5" ""; do
  reset_sbx
  printf '%s\n' "$stamp" > "$CACHE"
  SH=sh; command -v dash >/dev/null 2>&1 && SH=dash
  echo "$stop_stdin" | "$SH" "$STUB_LAUNCHER" 2>"$SBX/l4.err"
  rc=$?
  [ "$rc" -eq 0 ] && ok "corrupt stamp '$stamp' → launcher exits 0 (no fatal arith)" \
                  || bad "corrupt stamp '$stamp' → launcher exits 0" "rc=$rc $(cat "$SBX/l4.err")"
  worker_ran && ok "corrupt stamp '$stamp' → treated as stale, worker spawned" \
             || bad "corrupt stamp '$stamp' → worker spawned"
done

# ══════════════════════════════════════════════════════════════════════════
# LAYER 2 — the REAL worker, driven synchronously. No detach, no race.
# ══════════════════════════════════════════════════════════════════════════

# W1 — happy path: stamp line + one scoped line, name last.
reset_sbx
sh "$WORKER"; rc=$?
[ "$rc" -eq 0 ] && ok "worker exits 0 on happy path" || bad "worker exits 0 on happy path" "rc=$rc"
[ -f "$SBX/security.argv" ] && ok "stub security was used (no real Keychain read)" \
                            || bad "stub security was used" "the hook bypassed PATH — REAL keychain may have been hit"
[ -f "$SBX/curl.argv" ] && ok "stub curl was used (no real network)" \
                        || bad "stub curl was used" "the hook bypassed PATH — REAL endpoint may have been hit"
if [ -f "$CACHE" ]; then
  { read -r c_stamp; read -r c_pct c_reset c_name; } < "$CACHE"
  d=$(( $(now) - c_stamp )); [ "$d" -lt 0 ] && d=$(( -d ))
  [ "$d" -le 5 ] && ok "line 1 is the fetch epoch" || bad "line 1 is the fetch epoch" "got '$c_stamp'"
  [ "$c_pct" = "2" ]            && ok "scoped pct parsed"   || bad "scoped pct parsed" "got '$c_pct'"
  [ "$c_reset" = "$RESETS_EPOCH" ] && ok "resets_at → epoch" || bad "resets_at → epoch" "got '$c_reset' want '$RESETS_EPOCH'"
  [ "$c_name" = "Fable" ]       && ok "scoped name parsed"  || bad "scoped name parsed" "got '$c_name'"
  [ "$(wc -l < "$CACHE" | tr -d ' ')" = "2" ] && ok "session/weekly_all entries dropped (scope:null)" \
                                              || bad "session/weekly_all entries dropped" "$(cat "$CACHE")"
else
  bad "worker writes the cache" "no $CACHE"
fi

# W2 — the live OAuth token must never reach argv (ps aux is world-readable).
if [ -f "$SBX/curl.argv" ]; then
  grep -q "$TOKEN" "$SBX/curl.argv" && bad "token must NOT appear in curl argv" "$(cat "$SBX/curl.argv")" \
                                    || ok "token absent from curl argv"
  grep -q "config" "$SBX/curl.argv" && ok "curl invoked with --config" || bad "curl invoked with --config" "$(cat "$SBX/curl.argv")"
  grep -q "Bearer $TOKEN" "$SBX/curl.stdin" && ok "token passed via stdin config" \
                                            || bad "token passed via stdin config" "$(cat "$SBX/curl.stdin")"
  grep -q "oauth-2025-04-20" "$SBX/curl.stdin" && ok "anthropic-beta header sent" \
                                               || bad "anthropic-beta header sent" "$(cat "$SBX/curl.stdin")"
fi

# W3 — curl fails → last-good cache must SURVIVE untouched, worker exits 2.
reset_sbx
printf '%s\n7 %s Fable\n' "$(( $(now) - 9999 ))" "$RESETS_EPOCH" > "$CACHE"
before=$(cat "$CACHE")
echo 22 > "$SBX/curl.exit"
sh "$WORKER"; rc=$?
[ "$rc" -eq 2 ] && ok "curl failure → exit 2 (benign no-op)" || bad "curl failure → exit 2" "rc=$rc"
[ "$(cat "$CACHE")" = "$before" ] && ok "curl failure → cache untouched (last-good survives)" \
                                  || bad "curl failure → cache untouched" "$(cat "$CACHE")"

# W4 — malformed JSON → cache untouched.
reset_sbx
printf '%s\n7 %s Fable\n' "$(( $(now) - 9999 ))" "$RESETS_EPOCH" > "$CACHE"
before=$(cat "$CACHE")
printf 'not json at all' > "$SBX/curl.out"
sh "$WORKER"; rc=$?
[ "$rc" -eq 2 ] && ok "malformed JSON → exit 2" || bad "malformed JSON → exit 2" "rc=$rc"
[ "$(cat "$CACHE")" = "$before" ] && ok "malformed JSON → cache untouched" || bad "malformed JSON → cache untouched"

# W5 — response without limits[] (schema drifted / older API) → cache untouched.
reset_sbx
printf '%s\n7 %s Fable\n' "$(( $(now) - 9999 ))" "$RESETS_EPOCH" > "$CACHE"
before=$(cat "$CACHE")
printf '{"five_hour":{"utilization":18},"seven_day":{"utilization":4}}' > "$SBX/curl.out"
sh "$WORKER"; rc=$?
[ "$rc" -eq 2 ] && ok "no limits[] → exit 2" || bad "no limits[] → exit 2" "rc=$rc"
[ "$(cat "$CACHE")" = "$before" ] && ok "no limits[] → cache untouched" || bad "no limits[] → cache untouched"

# W6 — limits[] present but zero scoped windows → stamp-only cache. Without the
# stamp line this would re-fetch on EVERY turn (nothing to TTL-gate against).
reset_sbx
printf '{"limits":[{"kind":"session","percent":18,"scope":null}]}' > "$SBX/curl.out"
sh "$WORKER"; rc=$?
[ "$rc" -eq 0 ] && ok "zero scoped windows → exit 0" || bad "zero scoped windows → exit 0" "rc=$rc"
[ "$(wc -l < "$CACHE" | tr -d ' ')" = "1" ] && ok "zero scoped windows → stamp-only cache (TTL still gates)" \
                                            || bad "zero scoped windows → stamp-only cache" "$(cat "$CACHE")"

# W7 — a display_name containing spaces must survive: name is the LAST field, so
# a plain POSIX `read pct reset name` slurps the remainder.
reset_sbx
response 41 "Claude Opus 4.8" > "$SBX/curl.out"
sh "$WORKER"
{ read -r _; read -r w_pct w_reset w_name; } < "$CACHE"
[ "$w_name" = "Claude Opus 4.8" ] && ok "display_name with spaces preserved" || bad "display_name with spaces preserved" "got '$w_name'"
[ "$w_pct" = "41" ] && ok "pct still parses with a spaced name" || bad "pct still parses with a spaced name" "got '$w_pct'"

# W8 — no keychain item AND no credentials file → exit 2, no cache created.
reset_sbx
rm -f "$SBX/security.out"          # stub now exits 44, like errSecItemNotFound
sh "$WORKER"; rc=$?
[ "$rc" -eq 2 ] && ok "no token → exit 2" || bad "no token → exit 2" "rc=$rc"
[ -f "$CACHE" ] && bad "no token → no cache written" || ok "no token → no cache written"
[ -f "$SBX/curl.argv" ] && bad "no token → curl must not run" || ok "no token → curl must not run"

# W9 — Keychain miss falls back to plaintext ~/.claude/.credentials.json (Linux/WSL).
reset_sbx
rm -f "$SBX/security.out"
creds > "$HOME/.claude/.credentials.json"
sh "$WORKER"; rc=$?
rm -f "$HOME/.claude/.credentials.json"
[ "$rc" -eq 0 ] && ok "keychain miss → falls back to .credentials.json" || bad "keychain miss → falls back to .credentials.json" "rc=$rc"
grep -q "Bearer $TOKEN" "$SBX/curl.stdin" 2>/dev/null && ok "fallback token reaches curl" || bad "fallback token reaches curl"

# W10 — a scoped entry with no resets_at gets epoch 0 (statusline hides the countdown).
reset_sbx
printf '{"limits":[{"kind":"weekly_scoped","percent":3,"resets_at":null,"scope":{"model":{"display_name":"Fable"}}}]}' > "$SBX/curl.out"
sh "$WORKER"
{ read -r _; read -r _ r_reset _; } < "$CACHE"
[ "$r_reset" = "0" ] && ok "missing resets_at → epoch 0 sentinel" || bad "missing resets_at → epoch 0 sentinel" "got '$r_reset'"

# W11 — atomic write leaves no tmp litter in hook_state/.
reset_sbx
sh "$WORKER"
extra=$(find "$STATE" -name 'usage_scoped*' ! -name 'usage_scoped' | wc -l | tr -d ' ')
[ "$extra" = "0" ] && ok "atomic write leaves no tmp files" || bad "atomic write leaves no tmp files" "$(find "$STATE" -name 'usage_scoped*')"

# W12 — cache must never be world-readable garbage: it holds no secret, but the
# worker must not leave the token anywhere on disk.
reset_sbx
sh "$WORKER"
grep -rq "$TOKEN" "$STATE" 2>/dev/null && bad "token must not be persisted to hook_state" || ok "token never persisted to disk"

# ══════════════════════════════════════════════════════════════════════════
# LAYER 3 — CLAUDE_CONFIG_DIR: the per-account bucket.
#
# A second account runs as `CLAUDE_CONFIG_DIR=~/.claude-work claude`. Its OAuth
# token lives in its OWN Keychain item and its usage cache must live in its OWN
# config dir, or the statusline prints one account's percentages under the other
# account's badge. Everything else the engine writes (hook_state markers,
# projects/) stays SHARED on $HOME/.claude BY DESIGN — a blanket swap breaks
# orphan-backstop.sh. See project_multi_account_config_dir in the project store.
#
# Keychain service naming, read off the live Keychain 2026-08-22:
#     default config dir  ->  "Claude Code-credentials"
#     CLAUDE_CONFIG_DIR   ->  "Claude Code-credentials-<sha256(dir)[:8]>"
# ══════════════════════════════════════════════════════════════════════════
CFG="$SBX/.claude-work"
CFG_CACHE="$CFG/hook_state/usage_scoped"
# Computed, never hardcoded — the digest is of the sandbox path, which moves.
CFG_SVC="Claude Code-credentials-$(printf %s "$CFG" | python3 -c \
  'import sys, hashlib; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:8])')"

reset_cfg() { reset_sbx; rm -rf "$CFG"; mkdir -p "$CFG/hook_state"; }

# C1 — the worker writes its cache INSIDE the config dir, and leaves the shared
# one alone. Two accounts sharing one usage_scoped show whoever fetched last.
reset_cfg
CLAUDE_CONFIG_DIR="$CFG" sh "$WORKER"; rc=$?
[ "$rc" -eq 0 ] && ok "cfg: worker exits 0 under CLAUDE_CONFIG_DIR" || bad "cfg: worker exits 0 under CLAUDE_CONFIG_DIR" "rc=$rc"
[ -f "$CFG_CACHE" ] && ok "cfg: cache lands in \$CLAUDE_CONFIG_DIR/hook_state" \
                    || bad "cfg: cache lands in \$CLAUDE_CONFIG_DIR/hook_state" "missing $CFG_CACHE"
[ -f "$CACHE" ] && bad "cfg: shared cache must NOT be written" "$(cat "$CACHE")" \
                || ok "cfg: shared cache untouched"

# C2 — the Keychain lookup carries the config-dir-scoped service name. Querying
# the unsuffixed item here returns the OTHER account's token.
grep -qF -- "$CFG_SVC" "$SBX/security.argv" 2>/dev/null \
  && ok "cfg: keychain queried with the scoped service name" \
  || bad "cfg: keychain queried with the scoped service name" \
         "want '$CFG_SVC' got '$(cat "$SBX/security.argv" 2>/dev/null)'"

# C3 — default account keeps the UNSUFFIXED name. Mutation pin: an unconditional
# suffix would query an item that does not exist for every single-account user.
reset_cfg
sh "$WORKER" >/dev/null 2>&1
grep -q 'Claude Code-credentials -a' "$SBX/security.argv" 2>/dev/null \
  && ok "cfg: no CLAUDE_CONFIG_DIR → unsuffixed service name" \
  || bad "cfg: no CLAUDE_CONFIG_DIR → unsuffixed service name" "$(cat "$SBX/security.argv" 2>/dev/null)"

# C4 — a trailing slash must not change the digest. `CLAUDE_CONFIG_DIR=~/x/` is
# a normal thing to type, and sha256("…/x/") != sha256("…/x").
reset_cfg
CLAUDE_CONFIG_DIR="$CFG/" sh "$WORKER" >/dev/null 2>&1
grep -qF -- "$CFG_SVC" "$SBX/security.argv" 2>/dev/null \
  && ok "cfg: trailing slash normalized before hashing" \
  || bad "cfg: trailing slash normalized before hashing" \
         "want '$CFG_SVC' got '$(cat "$SBX/security.argv" 2>/dev/null)'"

# C5 — the plaintext fallback (Linux/WSL) follows the config dir too.
reset_cfg
rm -f "$SBX/security.out"                 # keychain miss
creds > "$CFG/.credentials.json"
CLAUDE_CONFIG_DIR="$CFG" sh "$WORKER"; rc=$?
[ "$rc" -eq 0 ] && ok "cfg: falls back to \$CLAUDE_CONFIG_DIR/.credentials.json" \
               || bad "cfg: falls back to \$CLAUDE_CONFIG_DIR/.credentials.json" "rc=$rc"
grep -q "Bearer $TOKEN" "$SBX/curl.stdin" 2>/dev/null && ok "cfg: config-dir token reaches curl" \
                                                      || bad "cfg: config-dir token reaches curl"

# C6 — the PERSONAL plaintext file is not a fallback for a config-dir session.
# Reading it would report the personal account's usage under the work badge.
reset_cfg
rm -f "$SBX/security.out"
creds > "$HOME/.claude/.credentials.json"
CLAUDE_CONFIG_DIR="$CFG" sh "$WORKER"; rc=$?
rm -f "$HOME/.claude/.credentials.json"
[ "$rc" -eq 2 ] && ok "cfg: shared .credentials.json is NOT a cross-account fallback" \
               || bad "cfg: shared .credentials.json is NOT a cross-account fallback" "rc=$rc"
[ -f "$CFG_CACHE" ] && bad "cfg: no token → no config-dir cache" "$(cat "$CFG_CACHE")" \
                    || ok "cfg: no token → no config-dir cache"

# C6b — CLAUDE_CONFIG_DIR pointing AT the default dir must keep the unsuffixed
# name. Exporting CLAUDE_CONFIG_DIR=$HOME/.claude in a shell rc is a normal
# thing to do, and that account's item is the plain one — gating on the
# variable's PRESENCE rather than on the resolved path silently blanks the
# segment for a configuration that works today.
reset_cfg
CLAUDE_CONFIG_DIR="$HOME/.claude" sh "$WORKER" >/dev/null 2>&1
grep -q 'Claude Code-credentials -a' "$SBX/security.argv" 2>/dev/null \
  && ok "cfg: CLAUDE_CONFIG_DIR = the default dir → unsuffixed service name" \
  || bad "cfg: CLAUDE_CONFIG_DIR = the default dir → unsuffixed service name" \
         "$(cat "$SBX/security.argv" 2>/dev/null)"
[ -f "$CACHE" ] && ok "cfg: CLAUDE_CONFIG_DIR = the default dir → shared cache path" \
                || bad "cfg: CLAUDE_CONFIG_DIR = the default dir → shared cache path"

# C7 — the launcher TTL-gates against the config-dir cache.
reset_cfg
printf '%s\n2 %s Fable\n' "$(now)" "$RESETS_EPOCH" > "$CFG_CACHE"
echo "$stop_stdin" | CLAUDE_CONFIG_DIR="$CFG" sh "$STUB_LAUNCHER"
sleep 0.3
[ -f "$SBX/worker.ran" ] && bad "cfg: fresh config-dir cache → worker must NOT spawn" \
                         || ok "cfg: fresh config-dir cache → worker must NOT spawn"

# C8 — the SHARED cache must not gate a config-dir session: that stamp belongs
# to the other account, so honouring it starves this account of any refresh.
reset_cfg
printf '%s\n2 %s Fable\n' "$(now)" "$RESETS_EPOCH" > "$CACHE"
echo "$stop_stdin" | CLAUDE_CONFIG_DIR="$CFG" sh "$STUB_LAUNCHER"
worker_ran && ok "cfg: fresh SHARED cache does not gate a config-dir session" \
           || bad "cfg: fresh SHARED cache does not gate a config-dir session"

# ══════════════════════════════════════════════════════════════════════════
# LAYER 4 — structural: the bucket boundary itself.
#
# Bucket 2 is deliberately TINY. Every other hook_state/projects path must stay
# on $HOME/.claude even under a second config dir, because those index the
# SHARED transcript tree — a blanket swap silently degrades orphan-backstop.sh
# (each account scans the other's transcripts with none of its own stamps).
# Scan CODE only, comments stripped: the prose above explains the rule and would
# otherwise satisfy a presence-only grep.
# ══════════════════════════════════════════════════════════════════════════
ENGINE="$HERE/.."
allowed="fetch-usage.sh fetch-usage-worker.sh statusline-command.sh"
offenders=""
for f in "$ENGINE"/hooks/*.sh "$ENGINE"/hooks/*.mjs "$ENGINE"/statusline-command.sh; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  case " $allowed " in *" $base "*) continue ;; esac
  sed -e 's/^[[:space:]]*#.*$//' -e 's|^[[:space:]]*//.*$||' "$f" \
    | grep -q 'CLAUDE_CONFIG_DIR' && offenders="$offenders $base"
done
[ -z "$offenders" ] && ok "bucket boundary: only the usage trio follows CLAUDE_CONFIG_DIR" \
                    || bad "bucket boundary: only the usage trio follows CLAUDE_CONFIG_DIR" \
                           "shared-data state must stay on \$HOME/.claude —$offenders"

# statusline-command.sh is allowlisted wholesale above because it legitimately
# holds BOTH buckets: HOOK_STATE_DIR (shared markers) and USAGE_CFG_DIR
# (per-account). A blanket swap of the SHARED one would sail through the scan,
# so pin it by value and cap the per-account readers at exactly the two known
# sites — the account badge and the usage cache.
SL="$ENGINE/statusline-command.sh"
grep -q 'HOOK_STATE_DIR="$HOME/.claude/hook_state"' "$SL" \
  && ok "bucket boundary: statusline HOOK_STATE_DIR stays on \$HOME/.claude" \
  || bad "bucket boundary: statusline HOOK_STATE_DIR stays on \$HOME/.claude" \
         "$(grep -n 'HOOK_STATE_DIR=' "$SL")"
n=$(sed -e 's/^[[:space:]]*#.*$//' "$SL" | grep -c 'CLAUDE_CONFIG_DIR')
[ "$n" = "2" ] && ok "bucket boundary: statusline reads CLAUDE_CONFIG_DIR at exactly 2 sites" \
               || bad "bucket boundary: statusline reads CLAUDE_CONFIG_DIR at exactly 2 sites" \
                      "got $n — badge + usage cache are the only per-account readers"

# The three that DO follow it must actually still do so (a deleted line would
# otherwise pass the scan above by being absent everywhere).
for base in fetch-usage.sh fetch-usage-worker.sh; do
  grep -q 'CLAUDE_CONFIG_DIR' "$ENGINE/hooks/$base" \
    && ok "bucket boundary: $base reads CLAUDE_CONFIG_DIR" \
    || bad "bucket boundary: $base reads CLAUDE_CONFIG_DIR"
done
grep -q 'CLAUDE_CONFIG_DIR' "$ENGINE/statusline-command.sh" \
  && ok "bucket boundary: statusline-command.sh reads CLAUDE_CONFIG_DIR" \
  || bad "bucket boundary: statusline-command.sh reads CLAUDE_CONFIG_DIR"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "$fail FAILED"
exit $((fail > 0))
