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
  while [ $n -lt 60 ]; do [ -f "$SBX/worker.ran" ] && return 0; sleep 0.05; n=$((n+1)); done
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

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "$fail FAILED"
exit $((fail > 0))
