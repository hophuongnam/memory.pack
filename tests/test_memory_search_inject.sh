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

# --- indexer: CRLF + BOM fence tolerance (mirror of _lib.mjs fmParse) ------
# A CRLF checkout / Windows edit produced `---\r\n` fences the parser
# rejected (type='' → unfiltered noise rows); utf-8 read keeps a BOM as
# ﻿ which defeated startswith("---").
printf -- '---\r\nname: feedback_crlf_doc\r\ndescription: crlf checkout lesson\r\ntype: feedback\r\n---\r\nNotepad checkouts produce CRLF memory files.\r\n' \
  > "$MEMDIR/feedback_crlf_doc.md"
printf '\357\273\277---\nname: feedback_bom_doc\ndescription: bom sig lesson\ntype: feedback\n---\nBOM body.\n' \
  > "$MEMDIR/feedback_bom_doc.md"
python3 "$INDEXER" --file "$MEMDIR/feedback_crlf_doc.md" --quiet 2>/dev/null
python3 "$INDEXER" --file "$MEMDIR/feedback_bom_doc.md" --quiet 2>/dev/null
t=$(sqlite3 "$DB" "SELECT type FROM memories WHERE basename='feedback_crlf_doc.md';" 2>/dev/null)
[ "$t" = "feedback" ] \
  && ok "indexer: CRLF fences resolve type" \
  || bad "indexer: CRLF fences resolve type" "type='$t'"
t=$(sqlite3 "$DB" "SELECT type FROM memories WHERE basename='feedback_bom_doc.md';" 2>/dev/null)
[ "$t" = "feedback" ] \
  && ok "indexer: utf-8-sig BOM resolves type" \
  || bad "indexer: utf-8-sig BOM resolves type" "type='$t'"

# --- indexer: same-second content edit must not stay stale forever ---------
# int(st_mtime) equality made a second edit within the same wall-clock
# second invisible to --file upsert AND reconcile (equal ints forever).
# mtime_ns is the identity now. Deterministic: explicit os.utime ns values
# inside the same second.
cat > "$MEMDIR/feedback_samesec.md" <<'MD'
---
name: feedback_samesec
description: same second edit fixture
type: feedback
---
original samesec body
MD
python3 -c "import os,sys; os.utime(sys.argv[1], ns=(1779700000000000111, 1779700000000000111))" "$MEMDIR/feedback_samesec.md"
python3 "$INDEXER" --file "$MEMDIR/feedback_samesec.md" --quiet 2>/dev/null
cat > "$MEMDIR/feedback_samesec.md" <<'MD'
---
name: feedback_samesec
description: same second edit fixture
type: feedback
---
REWRITTEN samesec body mariposa
MD
python3 -c "import os,sys; os.utime(sys.argv[1], ns=(1779700000000000222, 1779700000000000222))" "$MEMDIR/feedback_samesec.md"
python3 "$INDEXER" --file "$MEMDIR/feedback_samesec.md" --quiet 2>/dev/null
body=$(sqlite3 "$DB" "SELECT body FROM memories WHERE basename='feedback_samesec.md';" 2>/dev/null)
case "$body" in
  *mariposa*) ok "indexer: same-second edit re-indexed (mtime_ns identity)" ;;
  *) bad "indexer: same-second edit re-indexed (mtime_ns identity)" "body=[${body:0:80}]" ;;
esac

# --- indexer: corrupt search.db self-heals (derived state, workers muted) --
# Every indexer worker runs detached with stdio /dev/null'd: a corrupt db
# raised sqlite3.DatabaseError on every invocation and froze the index
# FOREVER with zero surface. The db is derived state — nuke and recreate.
printf 'this is not a sqlite database at all' > "$DB"
python3 "$INDEXER" --file "$MEMDIR/feedback_kafka_partitions.md" --quiet 2>/dev/null \
  && ok "indexer: corrupt db → exit 0 (recreated, not wedged)" \
  || bad "indexer: corrupt db → exit 0 (recreated, not wedged)"
rows=$(sqlite3 "$DB" "SELECT count(*) FROM memories;" 2>/dev/null)
[ -n "$rows" ] && [ "$rows" -ge 1 ] 2>/dev/null \
  && ok "indexer: recreated db is valid and holds the upsert (rows=$rows)" \
  || bad "indexer: recreated db is valid and holds the upsert" "rows='$rows'"
# Rebuild the full corpus for the cases below.
python3 "$INDEXER" --rebuild --quiet 2>/dev/null

# --- indexer: 'archive' in the HOST path must not flag the corpus ----------
# is_archived checked 'archive' against ABSOLUTE path parts, so a home
# like /srv/archive/home marked every active memory archived. The check
# must be relative to the memory root.
AHOME="$SBX/archive/home2"
AMEM="$AHOME/.claude/projects/-proj-beta/memory"
mkdir -p "$AMEM/archive"
cat > "$AMEM/feedback_hostpath.md" <<'MD'
---
name: feedback_hostpath
description: host path archive component fixture
type: feedback
---
Active memory under an archive-named host directory.
MD
cp "$AMEM/feedback_hostpath.md" "$AMEM/archive/feedback_hostarch.md"
ADB="$SBX/mph2/index/search.db"
HOME="$AHOME" MEMORY_PACK_HOME="$SBX/mph2" python3 "$INDEXER" --rebuild --quiet 2>/dev/null
st=$(sqlite3 "$ADB" "SELECT status FROM memories WHERE basename='feedback_hostpath.md';" 2>/dev/null)
[ "$st" = "active" ] \
  && ok "indexer: 'archive' in HOST path does not mark active rows archived" \
  || bad "indexer: 'archive' in HOST path does not mark active rows archived" "status='$st'"
st=$(sqlite3 "$ADB" "SELECT status FROM memories WHERE basename='feedback_hostarch.md';" 2>/dev/null)
[ "$st" = "archived" ] \
  && ok "indexer: real archive/ under an archive-named host still archived" \
  || bad "indexer: real archive/ under an archive-named host still archived" "status='$st'"

# --- inject: transcript blend must ignore isMeta entries (feedback loop) ---
# The engine's own injected blocks (memory hits, boot context) arrive as
# isMeta:true user entries in the transcript — blending them feeds our own
# output back into the query tokens on every follow-up prompt.
cat > "$MEMDIR/reference_poison.md" <<'MD'
---
name: reference_poison
description: quokka wombat zebra menagerie enclosure notes
type: reference
---
The quokka wombat zebra menagerie enclosure requires daily quokka wombat
zebra inspections of the menagerie enclosure fencing.
MD
python3 "$INDEXER" --file "$MEMDIR/reference_poison.md" --quiet 2>/dev/null

TRX="$SBX/trx.jsonl"
cat > "$TRX" <<'JL'
{"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"quokka wombat zebra menagerie enclosure quokka wombat zebra menagerie enclosure"}]}}
JL
OUT=$(printf '{"prompt":"hi pal buddy","transcript_path":"%s"}' "$TRX" | bash "$INJECT" 2>/dev/null)
[ -z "$OUT" ] \
  && ok "inject: isMeta transcript entries do NOT blend into the query" \
  || bad "inject: isMeta transcript entries do NOT blend into the query" "out=[${OUT:0:200}]"

cat > "$TRX" <<'JL'
{"type":"assistant","message":{"content":[{"type":"text","text":"we should inspect the quokka wombat zebra menagerie enclosure"}]}}
JL
OUT=$(printf '{"prompt":"hi pal buddy","transcript_path":"%s"}' "$TRX" | bash "$INJECT" 2>/dev/null)
case "$OUT" in
  *reference_poison.md*) ok "inject: non-isMeta transcript text still blends (filter not over-broad)" ;;
  *) bad "inject: non-isMeta transcript text still blends (filter not over-broad)" "out=[${OUT:0:200}]" ;;
esac

# --- inject: project display prefix derives from slugified \$HOME ----------
# The short_project display stripped a HARDCODED -Users-namhp-Resilio-Sync-
# prefix — every other host showed the full slug. Derive from slugified
# $HOME instead.
HOME_SLUG=$(printf '%s' "$HOME" | sed 's|[/.]|-|g')
GMEM="$HOME/.claude/projects/${HOME_SLUG}-proj-gamma/memory"
mkdir -p "$GMEM"
cat > "$GMEM/reference_gamma_doc.md" <<'MD'
---
name: reference_gamma_doc
description: axolotl paddock irrigation ledger
type: reference
---
The axolotl paddock irrigation ledger tracks axolotl paddock flow rates
and irrigation ledger anomalies.
MD
python3 "$INDEXER" --file "$GMEM/reference_gamma_doc.md" --quiet 2>/dev/null
OUT=$(run_inject "axolotl paddock irrigation ledger anomalies flow rates")
case "$OUT" in
  *"· proj-gamma]"*) ok "inject: display prefix derived from slugified HOME" ;;
  *) bad "inject: display prefix derived from slugified HOME" "out=[${OUT:0:250}]" ;;
esac

# --- memory-index-update.sh: skip list + nested paths (stubbed python3) ----
# sessions.log.md must NOT be skipped — the indexer deliberately indexes it
# as type=session (index-memories.py SKIP_BASENAMES comment); the hook's
# skip list contradicted that, so live edits to session logs went stale
# until SessionEnd reconcile.
UPD="$HOOKS/memory-index-update.sh"
STUBBIN="$SBX/stub-bin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/python3" <<SH
#!/bin/sh
echo "\$@" >> "$SBX/indexer-calls.log"
SH
chmod +x "$STUBBIN/python3"
run_upd() {
  : > "$SBX/indexer-calls.log"
  printf '{"tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | PATH="$STUBBIN:$PATH" bash "$UPD" >/dev/null 2>&1
  i=0
  while [ "$i" -lt 10 ]; do
    [ -s "$SBX/indexer-calls.log" ] && break
    sleep 0.1; i=$((i + 1))
  done
  cat "$SBX/indexer-calls.log" 2>/dev/null
}
calls=$(run_upd "$MEMDIR/sessions.log.md")
case "$calls" in
  *sessions.log.md*) ok "index-update hook: sessions.log.md IS re-indexed (skip-list contradiction fixed)" ;;
  *) bad "index-update hook: sessions.log.md IS re-indexed" "calls=[$calls]" ;;
esac
calls=$(run_upd "$MEMDIR/MEMORY.md")
[ -z "$calls" ] \
  && ok "index-update hook: MEMORY.md still skipped" \
  || bad "index-update hook: MEMORY.md still skipped" "calls=[$calls]"
calls=$(run_upd "$MEMDIR/archive/sub/feedback_nested.md")
case "$calls" in
  *feedback_nested.md*) ok "index-update hook: nested archive path passes the glob (case * crosses /)" ;;
  *) bad "index-update hook: nested archive path passes the glob" "calls=[$calls]" ;;
esac

# --- search CLI: missing / 0-byte db hint -----------------------------------
SEARCH="$HERE/../index/search-memories.py"
errout=$(MEMORY_PACK_HOME="$SBX/nohere" python3 "$SEARCH" kafka 2>&1 >/dev/null); rc=$?
[ "$rc" = "2" ] \
  && ok "search CLI: missing db → exit 2" \
  || bad "search CLI: missing db → exit 2" "rc=$rc"
case "$errout" in
  *'$MEMORY_PACK_HOME/index/index-memories.py --rebuild'*)
    ok "search CLI: hint names \$MEMORY_PACK_HOME/index (host-correct static text)" ;;
  *) bad "search CLI: hint names \$MEMORY_PACK_HOME/index" "err=[$errout]" ;;
esac
mkdir -p "$SBX/zerodb/index"; : > "$SBX/zerodb/index/search.db"
errout=$(MEMORY_PACK_HOME="$SBX/zerodb" python3 "$SEARCH" kafka 2>&1 >/dev/null); rc=$?
[ "$rc" = "2" ] \
  && ok "search CLI: 0-byte db → exit 2 with hint (not a 'no such table' crash)" \
  || bad "search CLI: 0-byte db → exit 2 with hint" "rc=$rc err=[${errout:0:160}]"

echo "----"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
