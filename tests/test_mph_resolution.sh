#!/bin/bash
# TDD: MEMORY_PACK_HOME engine-root resolution across the 3 functional call
# sites (index-memories.py, search-memories.py, memory-search-inject.sh) +
# the invariant that NO hardcoded engine path survives anywhere in code.
#
# Contract:
#   python  DB = $MEMORY_PACK_HOME/index/search.db   (env set & non-empty)
#              = ~/.memory-pack/index/search.db       (env unset/empty)
#   bash    DB = $MEMORY_SEARCH_DB                     (most specific, kept)
#              = $MEMORY_PACK_HOME/index/search.db     (root override)
#              = $HOME/.memory-pack/index/search.db    (default)
#   Value-preservation: MEMORY_PACK_HOME=$HOME/Resilio.Sync/Memory.Pack
#   must resolve to the exact legacy db path (current Mac unchanged once
#   the installer sets the var).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WT="$(cd "$HERE/.." && pwd)"
PYI="$WT/index/index-memories.py"
PYS="$WT/index/search-memories.py"
HOOK="$WT/hooks/memory-search-inject.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      expected[%s] got[%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# --- python DB_PATH via module import (no main(), env-driven, db-existence
#     independent) ---
pydb() { # $1=script  $2=MEMORY_PACK_HOME value ("" = unset)
  if [ -z "$2" ]; then unset MEMORY_PACK_HOME; else export MEMORY_PACK_HOME="$2"; fi
  PYTHONDONTWRITEBYTECODE=1 python3 - "$1" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("m", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m.DB_PATH)
PY
  unset MEMORY_PACK_HOME
}

for label in index search; do
  case $label in index) S=$PYI;; search) S=$PYS;; esac
  chk "py/$label  env=/tmp/mpA" "/tmp/mpA/index/search.db" "$(pydb "$S" /tmp/mpA)"
  chk "py/$label  unset->default" "$HOME/.memory-pack/index/search.db" "$(pydb "$S" "")"
  chk "py/$label  value-preserve" "$HOME/Resilio.Sync/Memory.Pack/index/search.db" \
      "$(pydb "$S" "$HOME/Resilio.Sync/Memory.Pack")"
done

# --- bash hook DB= line, evaluated from the actual file under controlled env ---
DBLINE=$(grep -m1 '^DB=' "$HOOK")
bashdb() { # $1=MEMORY_SEARCH_DB  $2=MEMORY_PACK_HOME  (empty = unset semantics)
  env -i HOME="$HOME" PATH="$PATH" MEMORY_SEARCH_DB="$1" MEMORY_PACK_HOME="$2" \
    bash -c "$DBLINE"'; printf %s "$DB"'
}
chk "bash  MEMORY_SEARCH_DB wins" "/explicit/x.db" "$(bashdb /explicit/x.db /tmp/mpB)"
chk "bash  MEMORY_PACK_HOME root" "/tmp/mpB/index/search.db" "$(bashdb '' /tmp/mpB)"
chk "bash  neither -> default" "$HOME/.memory-pack/index/search.db" "$(bashdb '' '')"
chk "bash  value-preserve" "$HOME/Resilio.Sync/Memory.Pack/index/search.db" \
    "$(bashdb '' "$HOME/Resilio.Sync/Memory.Pack")"

# --- invariant: no hardcoded engine path anywhere in code ---
rm -rf "$WT/index/__pycache__" 2>/dev/null || true
# Contract is "no engine path in EXECUTABLE SOURCE". Two classes are
# legitimately allowed and must be filtered out:
#   1. comment-only lines (migration docs) — drop `file:lineno:` rows whose
#      content starts with # or //.
#   2. runtime-state artifacts — .boot-context-*/.boot-marker-*/.replay-*/
#      .skip-replay-* are ephemeral DATA, not engine code (install.sh:92-93
#      excludes the exact same set from the package). Their replay-summary
#      prose can quote the project path verbatim, which says nothing about
#      source. Mirror that EXCL list so the scan stays source-only.
HITS=$(grep -rnI --exclude-dir=__pycache__ \
  --exclude='.boot-context-*' --exclude='.boot-marker-*' \
  --exclude='.replay-*' --exclude='.skip-replay-*' \
  'Resilio\.Sync/Memory\.Pack' "$WT/hooks" "$WT/index" 2>/dev/null \
  | grep -vE ':[0-9]+:[[:space:]]*(#|//)' || true)
if [ -z "$HITS" ]; then
  ok "no 'Resilio.Sync/Memory.Pack' literal survives in hooks/ + index/"
else
  bad "hardcoded engine path still present" "(none)" "$(printf '%s' "$HITS" | wc -l | tr -d ' ') hit(s)"
  printf '%s\n' "$HITS" | sed 's/^/      /'
fi

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fail FAILED"; exit 1; fi
