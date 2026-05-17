#!/bin/bash
# TDD: install/merge-settings.sh must merge the 11 Memory.Pack hook entries
# into an EXISTING ~/.claude/settings.json that also contains foreign
# (SuperIsland) hooks, a null-command hook entry (real hazard seen in the
# live file), a stale MP entry under an old prefix, plus unrelated
# top-level keys (.permissions, .env, .theme). It must:
#   - inject all 11 MP entries with command = $PREFIX/hooks/<script>
#   - be idempotent (run twice -> byte-identical)
#   - replace stale-prefix MP entries (upgrade path)
#   - NEVER drop/alter foreign entries, the null-command entry, or any
#     non-hook top-level key
#   - set .env.MEMORY_PACK_HOME=$PREFIX without disturbing other .env keys
#   - --uninstall: remove ONLY MP entries + .env.MEMORY_PACK_HOME, leaving
#     everything else exactly as it was pre-install
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WT="$(cd "$HERE/.." && pwd)"
MERGE="$WT/install/merge-settings.sh"
MAN="$WT/install/hooks.manifest.json"
PREFIX="/opt/memory-pack"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# --- synthetic target settings.json: foreign hooks + null command + stale
#     MP entry + unrelated keys ---
cat > "$TMP/settings.json" <<'JSON'
{
  "theme": "dark",
  "permissions": { "allow": ["Bash(ls:*)"] },
  "env": { "CLAUDE_CODE_EFFORT_LEVEL": "max", "ENABLE_TOOL_SEARCH": "1" },
  "hooks": {
    "PostToolUse": [
      { "matcher": "Read", "hooks": [ { "type": "command", "command": "/old/Memory.Pack/hooks/memory-recall.sh", "timeout": 3 } ] },
      { "hooks": [ { "type": "command", "command": "/Applications/SuperIsland.app/hooks/cc-event-hook.sh Auto" } ] },
      { "matcher": "Bar", "hooks": [ { "type": "command" } ] }
    ],
    "PreToolUse": [
      { "hooks": [ { "type": "command", "command": "/Applications/SuperIsland.app/hooks/cc-event-hook.sh Working" } ] }
    ]
  }
}
JSON

if [ ! -f "$MERGE" ]; then echo "FAIL  install/merge-settings.sh missing ($MERGE)"; exit 1; fi

# --- install merge ---
"$MERGE" --prefix "$PREFIX" --manifest "$MAN" < "$TMP/settings.json" > "$TMP/after.json" 2>"$TMP/err" \
  || { bad "merge exits 0" "$(cat "$TMP/err")"; echo "----"; echo "$fail FAILED"; exit 1; }
jq -e . "$TMP/after.json" >/dev/null 2>&1 && ok "output is valid JSON" || bad "output is valid JSON" "$(cat "$TMP/err")"

mpcount() { jq '[.hooks[]?[]?.hooks[]? | select((.command//"")|test("/hooks/(boot-inject|session-end|memory-index-reconcile|memory-index-update|memory-recall|archive-resurrect|memory-search-inject|auto-save-stop)\\.sh$"))] | length' "$1"; }
c=$(mpcount "$TMP/after.json")
[ "$c" = "11" ] && ok "all 11 MP entries present" || bad "all 11 MP entries present" "got $c"

# every MP command uses the new prefix; none keep the stale /old prefix
badpfx=$(jq -r '[.hooks[]?[]?.hooks[]?.command//empty | select(test("/hooks/(boot-inject|session-end|memory-index-reconcile|memory-index-update|memory-recall|archive-resurrect|memory-search-inject|auto-save-stop)\\.sh$")) | select(startswith("'"$PREFIX"'/hooks/")|not)] | length' "$TMP/after.json")
[ "$badpfx" = "0" ] && ok "all MP commands use new prefix (stale replaced)" || bad "stale prefix replaced" "$badpfx wrong-prefix"

# spot-check a specific entry: PostToolUse/MultiEdit -> memory-index-update.sh t=3
jq -e '.hooks.PostToolUse[]?|select(.matcher=="MultiEdit")|.hooks[]?|select(.command=="'"$PREFIX"'/hooks/memory-index-update.sh" and .timeout==3)' "$TMP/after.json" >/dev/null \
  && ok "PostToolUse/MultiEdit wired correctly" || bad "PostToolUse/MultiEdit wired correctly"

# foreign SuperIsland entries survive (2: PostToolUse + PreToolUse)
fc=$(jq '[.hooks[]?[]?.hooks[]?.command//empty | select(test("cc-event-hook\\.sh"))] | length' "$TMP/after.json")
[ "$fc" = "2" ] && ok "foreign SuperIsland hooks intact" || bad "foreign SuperIsland hooks intact" "got $fc/2"

# null-command entry preserved (the line-242 hazard) — still there, no crash
nc=$(jq '[.hooks.PostToolUse[]?|select(.matcher=="Bar")] | length' "$TMP/after.json")
[ "$nc" = "1" ] && ok "null-command entry preserved" || bad "null-command entry preserved" "got $nc"

# unrelated top-level keys untouched; env augmented not replaced
jq -e '.theme=="dark" and .permissions.allow==["Bash(ls:*)"] and .env.CLAUDE_CODE_EFFORT_LEVEL=="max" and .env.ENABLE_TOOL_SEARCH=="1"' "$TMP/after.json" >/dev/null \
  && ok "unrelated keys + existing env preserved" || bad "unrelated keys + existing env preserved"
jq -e '.env.MEMORY_PACK_HOME=="'"$PREFIX"'"' "$TMP/after.json" >/dev/null \
  && ok ".env.MEMORY_PACK_HOME set to prefix" || bad ".env.MEMORY_PACK_HOME set to prefix"

# idempotent: merge again -> byte-identical (canonicalized)
"$MERGE" --prefix "$PREFIX" --manifest "$MAN" < "$TMP/after.json" > "$TMP/after2.json" 2>/dev/null
if diff <(jq -S . "$TMP/after.json") <(jq -S . "$TMP/after2.json") >/dev/null; then ok "idempotent (merge∘merge == merge)"; else bad "idempotent"; fi

# uninstall: only MP + MEMORY_PACK_HOME removed; foreign/null/keys intact
"$MERGE" --prefix "$PREFIX" --manifest "$MAN" --uninstall < "$TMP/after.json" > "$TMP/un.json" 2>/dev/null
[ "$(mpcount "$TMP/un.json")" = "0" ] && ok "uninstall removes all MP entries" || bad "uninstall removes all MP entries"
jq -e '(.env|has("MEMORY_PACK_HOME")|not) and .env.CLAUDE_CODE_EFFORT_LEVEL=="max"' "$TMP/un.json" >/dev/null \
  && ok "uninstall drops MEMORY_PACK_HOME, keeps other env" || bad "uninstall env cleanup"
unfc=$(jq '[.hooks[]?[]?.hooks[]?.command//empty|select(test("cc-event-hook\\.sh"))]|length' "$TMP/un.json")
unnc=$(jq '[.hooks.PostToolUse[]?|select(.matcher=="Bar")]|length' "$TMP/un.json")
{ [ "$unfc" = "2" ] && [ "$unnc" = "1" ]; } && ok "uninstall leaves foreign + null-cmd intact" || bad "uninstall foreign/null intact" "foreign=$unfc null=$unnc"
jq -e '.theme=="dark" and .permissions.allow==["Bash(ls:*)"]' "$TMP/un.json" >/dev/null \
  && ok "uninstall leaves unrelated keys intact" || bad "uninstall unrelated keys"

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fail FAILED"; exit 1; fi
