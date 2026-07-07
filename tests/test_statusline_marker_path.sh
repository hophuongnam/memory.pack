#!/bin/bash
# TDD: statusline-command.sh must locate the per-session boot marker AND
# the .skip-replay sentinel in the SAME directory the writers
# (boot-inject.sh:30,47,222 / session-end.sh:5,65,97) put them — its own
# hooks/ dir, resolved through the ~/.claude/statusline-command.sh symlink
# — NOT a hardcoded ~/Resilio.Sync/Memory.Pack/hooks path. The legacy
# hardcoded path silently dead-ends the ✓booted / ⏳pending / ⏭skip-replay
# segments on every relocated (~/.memory-pack, --prefix) install: the
# markers exist but the reader looks in a dir that does not exist
# (BUG-statusline-boot-marker-path). This is the read-side analog of the
# silent-amnesia class — the indicator added to surface replay state
# becomes invisible exactly when it matters.
#
# Two layers, mirroring the project's two accepted patterns:
#   1. structural source-regression (test_sdk_resolve.mjs:62 idiom) —
#      code-only scan: legacy hardcoded path absent; GNU-only `readlink -f`
#      absent (BSD/macOS readlink has no -f — the engine's proven one-hop
#      idiom is bare `readlink ... || echo`, session-end.sh:86-87).
#   2. behavioral subprocess (test_install.sh idiom) — copy the REAL
#      script into a relocated fake $PREFIX, invoke it through an absolute
#      symlink (exactly how install.sh `ln -sfn`s ~/.claude/...), with a
#      marker + sentinel present, and assert the glyphs render.
# Plus a mutation check: flip the marker contents and confirm ⏳pending is
# distinguished from ✓booted (guards a fix that finds the dir but ignores
# the marker's contents).
#
# Clone-location-independent: resolve everything off $HERE, never a
# hard-coded absolute path (test_hash_shim.sh idiom).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SL="$HERE/../statusline-command.sh"
LIB="$HERE/../hooks/_lib.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "$2"; fail=$((fail+1)); }

[ -f "$SL" ]  || { echo "FAIL  statusline-command.sh missing ($SL)"; exit 1; }
[ -f "$LIB" ] || { echo "FAIL  hooks/_lib.sh missing ($LIB)";       exit 1; }

# --- layer 1: structural source-regression ------------------------------
# Strip comment lines (optional leading whitespace then '#') so a
# cautionary comment that names the legacy path cannot trip the guard —
# same code-only scan as test_sdk_resolve.mjs:62.
CODE="$(grep -v '^[[:space:]]*#' "$SL")"

if printf '%s\n' "$CODE" | grep -q 'Resilio\.Sync/Memory\.Pack/hooks'; then
  bad "no hardcoded ~/Resilio.Sync/Memory.Pack/hooks in code" \
      "legacy hardcoded hooks path still present — relocated installs dead-end"
else
  ok "no hardcoded ~/Resilio.Sync/Memory.Pack/hooks in code"
fi

if printf '%s\n' "$CODE" | grep -q 'readlink -f'; then
  bad "no GNU-only 'readlink -f' (BSD/macOS has no -f)" \
      "use bare 'readlink ... || echo' + cd/pwd like session-end.sh:86-87"
else
  ok "no GNU-only 'readlink -f' (BSD/macOS has no -f)"
fi

# --- layer 2: behavioral, relocated layout invoked via symlink ----------
# Mirror a real install: engine copied to $PREFIX (relocated — NOT under
# ~/Resilio.Sync), invoked through an absolute ~/.claude-style symlink
# (install.sh:129 `ln -sfn "$PREFIX/statusline-command.sh" "$SL_LINK"`).
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PREFIX="$TMP/.memory-pack"
mkdir -p "$PREFIX/hooks" "$TMP/fake-claude"
cp "$SL" "$PREFIX/statusline-command.sh"
chmod +x "$PREFIX/statusline-command.sh"
# Copy render helpers so the relocated statusline-command.sh can source them.
for _f in _lib.sh statusline-theme.sh statusline-icons.sh statusline-render.sh; do
  cp "$HERE/../hooks/$_f" "$PREFIX/hooks/"
done
LINK="$TMP/fake-claude/statusline-command.sh"
ln -s "$PREFIX/statusline-command.sh" "$LINK"      # absolute target, like install.sh

PROJ="$TMP/proj"; mkdir -p "$PROJ"
SID="test-session-0000-marker-path"
# Project hash via the canonical shim — value-identical to statusline's
# own mp_proj_hash (invariant #2, proven by test_hash_shim), so the
# sentinel filename matches what the script will look for.
# shellcheck disable=SC1090
. "$LIB"
PHASH="$(printf '%s' "$PROJ" | _mp_hash)"
[ -n "$PHASH" ] || { echo "FAIL  _mp_hash produced empty hash"; exit 1; }

printf 'loaded' > "$PREFIX/hooks/.boot-marker-${SID}"
: > "$PREFIX/hooks/.skip-replay-${PHASH}"

STDIN_JSON="$(printf '{"session_id":"%s","workspace":{"project_dir":"%s"},"model":{"display_name":"m"},"context_window":{"used_percentage":1}}' "$SID" "$PROJ")"

OUT="$(printf '%s' "$STDIN_JSON" | MEMORY_PACK_NERDFONT=0 "$LINK" 2>/dev/null)"

case "$OUT" in
  *"✓ booted"*) ok "✓ booted renders from relocated hooks/ (via symlink)" ;;
  *) bad "✓ booted renders from relocated hooks/ (via symlink)" \
         "marker not found at resolved path | out=[$OUT]" ;;
esac
case "$OUT" in
  *"⏭ skip-replay"*) ok "⏭ skip-replay renders from relocated hooks/ (via symlink)" ;;
  *) bad "⏭ skip-replay renders from relocated hooks/ (via symlink)" \
         "sentinel not found at resolved path | out=[$OUT]" ;;
esac

# --- mutation check: marker contents are honored, not just presence -----
printf 'pending' > "$PREFIX/hooks/.boot-marker-${SID}"
OUT2="$(printf '%s' "$STDIN_JSON" | MEMORY_PACK_NERDFONT=0 "$LINK" 2>/dev/null)"
case "$OUT2" in
  *"⏳ pending"*) ok "⏳ pending distinguished from ✓ booted (contents honored)" ;;
  *) bad "⏳ pending distinguished from ✓ booted (contents honored)" \
         "out=[$OUT2]" ;;
esac

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fail FAILED"; exit 1; fi
