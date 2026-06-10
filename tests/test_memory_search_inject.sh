#!/bin/bash
# Characterization suite for the FTS5 search pipeline — the two components
# that had no behavioral coverage: index-memories.py (build / nested-shape
# parse / incremental update / delete reconcile / skip-list) and
# memory-search-inject.sh (hit injection, threshold + coverage gates,
# slash-command and short-prompt skips). The DB is built by the REAL
# indexer over a sandboxed HOME store and queried through the REAL inject
# hook via MEMORY_SEARCH_DB — no fixtures pretend to be the pipeline.
#
# Negative controls double as mutation guards: an impossible BM25
# threshold and an irrelevant prompt must produce NO injection, so a
# filter that stops biting fails here rather than silently injecting
# noise into every prompt.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HERE/../hooks"
INDEXER="$HERE/../index/index-memories.py"
INJECT="$HOOKS/memory-search-inject.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

SBX=$(mktemp -d); trap 'rm -rf "$SBX"' EXIT
export HOME="$SBX/home"
export MEMORY_PACK_HOME="$SBX/mph"
MEMDIR="$HOME/.claude/projects/-proj-alpha/memory"
mkdir -p "$MEMDIR/archive" "$MEMORY_PACK_HOME/index"
DB="$MEMORY_PACK_HOME/index/search.db"
export MEMORY_SEARCH_DB="$DB"

# Fixture memories: one flat, one NESTED (stock system-prompt shape), one
# archived, plus skip-list files that must never index.
cat > "$MEMDIR/feedback_kafka_partitions.md" <<'MD'
---
name: feedback_kafka_partitions
description: kafka partition rebalancing strategy for the ingest cluster
type: feedback
---

Kafka partition rebalancing must drain the ingest cluster consumer group
before scaling; partition reassignment without draining loses offsets.
MD
cat > "$MEMDIR/project_nested_shape.md" <<'MD'
---
name: project_nested_shape
description: zeppelin dashboard migration timeline
metadata:
  type: project
---

Zeppelin dashboard migration scheduled.
MD
cat > "$MEMDIR/archive/feedback_old_archived.md" <<'MD'
---
name: feedback_old_archived
description: archived terraform drift lesson
type: feedback
---

Terraform drift detection lesson, archived.
MD
printf '# Memory Index\n' > "$MEMDIR/MEMORY.md"

# 12 unrelated filler memories. BM25's IDF term collapses toward 0 when a
# query term appears in most documents — in a 3-doc corpus the kafka doc
# ranked -0.00 and could NEVER clear the production -8.0 threshold. A
# padded corpus restores realistic IDF (the kafka doc ranks ≈ -15 here),
# so the test exercises the SHIPPED threshold instead of a bespoke one.
i=1
while [ "$i" -le 12 ]; do
  cat > "$MEMDIR/filler_$i.md" <<MD
---
name: filler_$i
description: unrelated note number $i about gardens and weather patterns
type: reference
---

Note $i covers greenhouse humidity, tulip soil acidity, and sprinkler
maintenance schedules for the botanical annex building $i.
MD
  i=$((i + 1))
done

# --- indexer: build -------------------------------------------------------
python3 "$INDEXER" --rebuild --quiet 2>/dev/null \
  && ok "indexer: --rebuild exits 0" \
  || bad "indexer: --rebuild exits 0"
[ -f "$DB" ] && ok "indexer: search.db created under MEMORY_PACK_HOME" \
  || bad "indexer: search.db created under MEMORY_PACK_HOME" "missing $DB"

rows=$(sqlite3 "$DB" "SELECT count(*) FROM memories;" 2>/dev/null)
[ "$rows" = "15" ] \
  && ok "indexer: 15 memories indexed (MEMORY.md skipped)" \
  || bad "indexer: 15 memories indexed (MEMORY.md skipped)" "rows=$rows"

t=$(sqlite3 "$DB" "SELECT type FROM memories WHERE basename='project_nested_shape.md';" 2>/dev/null)
[ "$t" = "project" ] \
  && ok "indexer: nested metadata: shape resolves type (whitespace-tolerant parse)" \
  || bad "indexer: nested metadata: shape resolves type" "type='$t'"

st=$(sqlite3 "$DB" "SELECT status FROM memories WHERE basename='feedback_old_archived.md';" 2>/dev/null)
[ "$st" = "archived" ] \
  && ok "indexer: archive/ rows carry status=archived" \
  || bad "indexer: archive/ rows carry status=archived" "status='$st'"

# --- indexer: incremental update + delete reconcile -----------------------
cat > "$MEMDIR/feedback_kafka_partitions.md" <<'MD'
---
name: feedback_kafka_partitions
description: kafka partition rebalancing strategy for the ingest cluster
type: feedback
---

UPDATED: rebalancing now uses the quartz scheduler window exclusively.
MD
python3 -c "import os, time; p='$MEMDIR/feedback_kafka_partitions.md'; st=os.stat(p); os.utime(p, (st.st_atime, st.st_mtime + 5))"
rm -f "$MEMDIR/project_nested_shape.md"
python3 "$INDEXER" --quiet 2>/dev/null

body=$(sqlite3 "$DB" "SELECT body FROM memories WHERE basename='feedback_kafka_partitions.md';" 2>/dev/null)
case "$body" in
  *"quartz scheduler"*) ok "indexer: incremental sync picks up edited body (mtime-advanced)" ;;
  *) bad "indexer: incremental sync picks up edited body" "body=[${body:0:80}]" ;;
esac
rows=$(sqlite3 "$DB" "SELECT count(*) FROM memories WHERE basename='project_nested_shape.md';" 2>/dev/null)
[ "$rows" = "0" ] \
  && ok "indexer: incremental sync deletes rows for removed files" \
  || bad "indexer: incremental sync deletes rows for removed files" "rows=$rows"

# --- inject hook: relevant prompt → hit with epistemic preamble -----------
run_inject() {
  printf '{"prompt":"%s","transcript_path":""}' "$1" | bash "$INJECT" 2>/dev/null
}

OUT=$(run_inject "how should kafka partition rebalancing work for the ingest cluster")
case "$OUT" in
  *feedback_kafka_partitions.md*) ok "inject: relevant prompt surfaces the matching memory" ;;
  *) bad "inject: relevant prompt surfaces the matching memory" "out=[${OUT:0:200}]" ;;
esac
case "$OUT" in
  *"verify before asserting"*) ok "inject: epistemic preamble present" ;;
  *) bad "inject: epistemic preamble present" "out=[${OUT:0:200}]" ;;
esac
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1 \
  && ok "inject: output is valid hookSpecificOutput JSON" \
  || bad "inject: output is valid hookSpecificOutput JSON" "out=[${OUT:0:120}]"

# --- inject hook: gates (each must produce NO output) ----------------------
# Vocabulary absent from EVERY fixture (fillers mention gardens, so the
# nonsense must not stem-match anything).
OUT=$(run_inject "zorbital quantum xylophone harmonics resonating chamber")
[ -z "$OUT" ] \
  && ok "inject: irrelevant prompt → no injection (coverage/threshold gate)" \
  || bad "inject: irrelevant prompt → no injection" "out=[${OUT:0:160}]"

OUT=$(run_inject "/memory-lint run the audit")
[ -z "$OUT" ] \
  && ok "inject: slash-command prompt → skipped" \
  || bad "inject: slash-command prompt → skipped" "out=[${OUT:0:120}]"

OUT=$(run_inject "ok")
[ -z "$OUT" ] \
  && ok "inject: sub-3-char prompt → skipped" \
  || bad "inject: sub-3-char prompt → skipped" "out=[${OUT:0:120}]"

# Impossible threshold (mutation guard: proves the BM25 gate actually bites
# — if the comparison were dropped, the kafka hit would still inject here).
OUT=$(MEMORY_SEARCH_THRESHOLD=-999 run_inject "kafka partition rebalancing ingest cluster")
[ -z "$OUT" ] \
  && ok "inject: impossible BM25 threshold suppresses the hit (gate bites)" \
  || bad "inject: impossible BM25 threshold suppresses the hit" "out=[${OUT:0:160}]"

# Missing DB → silent no-op (first-run before any index build).
OUT=$(MEMORY_SEARCH_DB="$SBX/nope.db" run_inject "kafka partition rebalancing ingest cluster")
[ -z "$OUT" ] \
  && ok "inject: missing search.db → silent no-op" \
  || bad "inject: missing search.db → silent no-op" "out=[${OUT:0:120}]"

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
