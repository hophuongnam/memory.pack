#!/usr/bin/env python3
"""
Query the auto-memory FTS5 index.

Usage:
  search-memories.py <query>...                # bm25-ranked top hits
  search-memories.py --status archived <q>     # only archived memories
  search-memories.py --type feedback <q>       # only feedback type
  search-memories.py --project Mira <q>        # substring on project slug
  search-memories.py --limit N <q>             # max results (default 20)
  search-memories.py --paths-only <q>          # only paths (one per line)
  search-memories.py --json <q>                # JSON output

Query syntax is FTS5 MATCH. Examples:
  sqlite WAL                  # both terms (implicit AND)
  sqlite OR postgres          # either
  "exact phrase"              # phrase
  type:feedback sqlite        # FTS5 column filter
  sql*                        # prefix (trailing star only)

Tips for callers:
  * The CLI does NOT auto-sync the index. Run `index-memories.py` first
    if you suspect drift; the PostToolUse + SessionEnd hooks normally
    keep it fresh.
  * BM25 is negative-log-odds — lower (more negative) = better. The
    [rank] column reflects the raw value; results are already sorted.
"""

import argparse
import json
import os
import pathlib
import sqlite3
import sys

_MPH = os.environ.get("MEMORY_PACK_HOME")
DB_PATH = (
    (pathlib.Path(_MPH) if _MPH else pathlib.Path.home() / ".memory-pack")
    / "index"
    / "search.db"
)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("query", nargs="+", help="FTS5 MATCH query")
    parser.add_argument(
        "--status", choices=["active", "archived"], help="filter by status"
    )
    parser.add_argument(
        "--type",
        help="filter by type (user|feedback|project|reference|session — accepted as free-form string so new types added by the indexer Just Work without a CLI bump)",
    )
    parser.add_argument("--project", help="substring filter on project slug")
    parser.add_argument(
        "--limit", type=int, default=20, help="max results (default 20)"
    )
    parser.add_argument(
        "--paths-only", action="store_true", help="print only paths"
    )
    parser.add_argument("--json", action="store_true", help="JSON output")
    args = parser.parse_args()

    # 0-byte counts as missing: sqlite would initialize it and then die on
    # "no such table" instead of showing the hint. The hint text is STATIC
    # $MEMORY_PACK_HOME phrasing — DB_PATH.parent pointed at the DB dir
    # (e.g. ~/.memory-pack/index/), where index-memories.py does not live.
    if not DB_PATH.exists() or DB_PATH.stat().st_size == 0:
        print(
            f"no index at {DB_PATH} — run "
            "`$MEMORY_PACK_HOME/index/index-memories.py --rebuild` "
            "(the indexer lives in the engine checkout) first",
            file=sys.stderr,
        )
        sys.exit(2)

    query = " ".join(args.query)
    where = ["memories MATCH ?"]
    params = [query]
    if args.status:
        where.append("status = ?")
        params.append(args.status)
    if args.type:
        where.append("type = ?")
        params.append(args.type)
    if args.project:
        where.append("project LIKE ?")
        params.append(f"%{args.project}%")

    sql = f"""
        SELECT
            bm25(memories) AS rank,
            abs_path, project, basename, status, type, name, description,
            snippet(memories, 3, '«', '»', '…', 12) AS snip
        FROM memories
        WHERE {' AND '.join(where)}
        ORDER BY rank
        LIMIT ?
    """
    params.append(args.limit)

    conn = sqlite3.connect(str(DB_PATH))
    try:
        try:
            rows = conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError as e:
            print(f"query error: {e}", file=sys.stderr)
            sys.exit(2)
    finally:
        conn.close()

    if args.json:
        out = [
            {
                "rank": r[0],
                "abs_path": r[1],
                "project": r[2],
                "basename": r[3],
                "status": r[4],
                "type": r[5],
                "name": r[6],
                "description": r[7],
                "snippet": r[8],
            }
            for r in rows
        ]
        print(json.dumps(out, indent=2))
        return

    if not rows:
        print("(no hits)")
        return

    for rank, abs_path, project, basename, status, type_, name, desc, snip in rows:
        if args.paths_only:
            print(abs_path)
            continue
        print(f"[{rank:.2f}] {abs_path}")
        meta = []
        if type_:
            meta.append(f"type={type_}")
        if status:
            meta.append(f"status={status}")
        if project:
            meta.append(f"project={project}")
        if meta:
            print(f"  {' '.join(meta)}")
        if name:
            print(f"  name: {name}")
        if desc:
            print(f"  desc: {desc}")
        if snip:
            print(f"  snip: {snip}")
        print()


if __name__ == "__main__":
    main()
