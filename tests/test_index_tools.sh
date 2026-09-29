#!/bin/bash
# The two index-side tools no suite drove (review 2026-09-29):
#   index/memory-links.py          — REWRITES memory bodies; its --selftest
#                                    passed but nothing ever called it
#   hooks/memory-index-reconcile.sh — the only catcher for out-of-band moves
#                                    (os.replace / mv fire no PostToolUse hook)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LINKS="$HERE/../index/memory-links.py"
RECON="$HERE/../hooks/memory-index-reconcile.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- memory-links.py ---------------------------------------------------------
out="$(python3 "$LINKS" --selftest 2>&1)"
[ "$out" = "selftest ok" ] \
  && ok "memory-links: --selftest passes" \
  || bad "memory-links: --selftest passes" "$out"

# Behavioral: canonicalize a link, leave no tmp litter, keep the file mode.
M="$TMP/mem"; mkdir -p "$M/archive"
printf -- '- [a](a_x.md)\n' > "$M/MEMORY.md"
printf 'see [c](c_y.md)\n' > "$M/a_x.md"; chmod 600 "$M/a_x.md"
printf 'leaf\n' > "$M/archive/c_y.md"
python3 "$LINKS" "$M" >/dev/null 2>&1
[ "$(cat "$M/a_x.md")" = "see [c](archive/c_y.md)" ] \
  && ok "memory-links: link to an archived file is rewritten" \
  || bad "memory-links: link to an archived file is rewritten" "$(cat "$M/a_x.md")"
[ -z "$(find "$M" -name '*.tmp*')" ] \
  && ok "memory-links: no tmp litter" \
  || bad "memory-links: no tmp litter" "$(find "$M" -name '*.tmp*')"
mode="$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$M/a_x.md")"
[ "$mode" = "0o600" ] \
  && ok "memory-links: rewrite keeps the file mode" \
  || bad "memory-links: rewrite keeps the file mode" "$mode"

# Structural: the rewrite is write+rename. An in-place open(path,"w")
# truncates the memory first, so an interrupt mid-write loses the body.
code="$(sed -n '/^def canonicalize/,/^def selftest/p' "$LINKS" | grep -v -E '^[[:space:]]*#')"
printf '%s' "$code" | grep -q 'os\.replace(' \
  && ok "memory-links: rewrite goes through os.replace" \
  || bad "memory-links: rewrite goes through os.replace" "absent"
printf '%s' "$code" | grep -q 'open(path, "w"' \
  && bad "memory-links: no in-place truncating write" "open(path, \"w\" present" \
  || ok "memory-links: no in-place truncating write"

# --- memory-index-reconcile.sh -----------------------------------------------
E="$TMP/engine"; mkdir -p "$E/hooks" "$E/index"
cp "$RECON" "$E/hooks/"
cat > "$E/index/index-memories.py" <<STUB
import sys
open("$TMP/indexer.args", "w").write(" ".join(sys.argv[1:]))
STUB
printf '{"session_id":"s"}' | bash "$E/hooks/memory-index-reconcile.sh" >"$TMP/recon.out" 2>&1
rc=$?
i=0; while [ ! -f "$TMP/indexer.args" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
[ "$rc" = "0" ] && [ ! -s "$TMP/recon.out" ] \
  && ok "reconcile: exits 0 with no output" \
  || bad "reconcile: exits 0 with no output" "rc=$rc out=$(cat "$TMP/recon.out")"
[ "$(cat "$TMP/indexer.args" 2>/dev/null)" = "--quiet" ] \
  && ok "reconcile: runs the co-located indexer with --quiet" \
  || bad "reconcile: runs the co-located indexer with --quiet" "args=[$(cat "$TMP/indexer.args" 2>/dev/null)]"

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
