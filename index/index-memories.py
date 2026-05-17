#!/usr/bin/env python3
"""
Incrementally sync auto-memory files into a SQLite FTS5 index.

Walks ~/.claude/projects/<slug>/memory/**/*.md (active and archive/),
parses YAML-ish frontmatter, and upserts into
$MEMORY_PACK_HOME/index/search.db (default ~/.memory-pack/).

Usage:
  index-memories.py                # incremental sync (default)
  index-memories.py --rebuild      # drop and rebuild from scratch
  index-memories.py --file PATH    # upsert/delete a single file (used by hook)
  index-memories.py --quiet        # suppress stdout

The index is a single SQLite file, no external service. Search is
keyword/BM25 via FTS5; see search-memories.py for the query side.
"""

import argparse
import os
import pathlib
import sqlite3
import sys

HOME = pathlib.Path.home()
PROJECTS_ROOT = HOME / ".claude" / "projects"
# Engine root is relocatable: $MEMORY_PACK_HOME if set (the installer sets
# it; on the original Mac it points at ~/Resilio.Sync/Memory.Pack so this
# path is unchanged), else ~/.memory-pack.
_MPH = os.environ.get("MEMORY_PACK_HOME")
DB_PATH = (pathlib.Path(_MPH) if _MPH else HOME / ".memory-pack") / "index" / "search.db"

SKIP_BASENAMES = {
    "MEMORY.md",
    "SESSIONS.md",
    "PENDING_MEMORIES.md",
    "SCHEMA.md",
}
# sessions.log.md is intentionally NOT in SKIP_BASENAMES — it carries
# narrative replay summaries that have searchable signal for cross-session
# topic continuity. read_record() synthesizes its frontmatter (no real
# frontmatter exists on these files) so it indexes as type="session".
SESSION_LOG_BASENAME = "sessions.log.md"

SCHEMA_SQL = """
CREATE VIRTUAL TABLE IF NOT EXISTS memories USING fts5(
  type,
  name,
  description,
  body,
  abs_path UNINDEXED,
  project UNINDEXED,
  basename UNINDEXED,
  status UNINDEXED,
  tokenize = 'porter unicode61'
);

CREATE TABLE IF NOT EXISTS files (
  abs_path TEXT PRIMARY KEY,
  rowid_in_fts INTEGER NOT NULL,
  mtime INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS files_rowid ON files(rowid_in_fts);
"""


def parse_frontmatter(text):
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end < 0:
        return {}, text
    fm_block = text[4:end]
    body = text[end + 5 :]
    fm = {}
    for line in fm_block.split("\n"):
        if ":" in line:
            k, _, v = line.partition(":")
            k = k.strip()
            v = v.strip()
            if k:
                fm[k] = v
    return fm, body


def project_slug(path: pathlib.Path) -> str:
    try:
        rel = path.relative_to(PROJECTS_ROOT)
        return rel.parts[0]
    except ValueError:
        return ""


def is_archived(path: pathlib.Path) -> bool:
    return "archive" in path.parts


def should_index(path: pathlib.Path) -> bool:
    if path.name in SKIP_BASENAMES:
        return False
    if path.name.startswith("."):
        return False
    if not path.name.endswith(".md"):
        return False
    return True


def read_record(path: pathlib.Path):
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    if path.name == SESSION_LOG_BASENAME:
        # No real frontmatter on session logs — synthesize the metadata so
        # they index uniformly. Status is always "active" (logs aren't
        # archived); type "session" lets searchers filter them in or out.
        slug = project_slug(path) or "unknown"
        return {
            "abs_path": str(path),
            "project": slug,
            "basename": path.name,
            "status": "active",
            "type": "session",
            "name": f"Session log — {slug}",
            "description": "Append-only replay summaries from prior sessions — searchable for cross-session topic continuity, decisions, and unwritten context that never got promoted to a memory.",
            "body": text,
        }
    fm, body = parse_frontmatter(text)
    return {
        "abs_path": str(path),
        "project": project_slug(path),
        "basename": path.name,
        "status": "archived" if is_archived(path) else "active",
        "type": fm.get("type", ""),
        "name": fm.get("name", ""),
        "description": fm.get("description", ""),
        "body": body,
    }


def walk_memory_files():
    if not PROJECTS_ROOT.is_dir():
        return
    for project_dir in sorted(PROJECTS_ROOT.iterdir()):
        mem_dir = project_dir / "memory"
        if not mem_dir.is_dir():
            continue
        for md in mem_dir.rglob("*.md"):
            if should_index(md):
                yield md


def open_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.executescript(SCHEMA_SQL)
    return conn


def upsert(conn, path: pathlib.Path) -> str:
    """Insert or update a single file. Returns 'inserted', 'updated', or 'skipped'."""
    rec = read_record(path)
    if rec is None:
        return "skipped"
    try:
        mtime = int(path.stat().st_mtime)
    except OSError:
        return "skipped"
    abs_path = rec["abs_path"]
    cur = conn.execute(
        "SELECT rowid_in_fts, mtime FROM files WHERE abs_path = ?", (abs_path,)
    )
    row = cur.fetchone()
    if row:
        rowid, prev_mtime = row
        if prev_mtime == mtime:
            return "skipped"
        conn.execute(
            "UPDATE memories SET type=?, name=?, description=?, body=?, "
            "project=?, basename=?, status=? WHERE rowid=?",
            (
                rec["type"],
                rec["name"],
                rec["description"],
                rec["body"],
                rec["project"],
                rec["basename"],
                rec["status"],
                rowid,
            ),
        )
        conn.execute(
            "UPDATE files SET mtime=? WHERE abs_path=?", (mtime, abs_path)
        )
        return "updated"
    cur = conn.execute(
        "INSERT INTO memories(type, name, description, body, "
        "abs_path, project, basename, status) VALUES (?,?,?,?,?,?,?,?)",
        (
            rec["type"],
            rec["name"],
            rec["description"],
            rec["body"],
            rec["abs_path"],
            rec["project"],
            rec["basename"],
            rec["status"],
        ),
    )
    conn.execute(
        "INSERT INTO files(abs_path, rowid_in_fts, mtime) VALUES (?,?,?)",
        (abs_path, cur.lastrowid, mtime),
    )
    return "inserted"


def delete_path(conn, abs_path: str) -> bool:
    cur = conn.execute(
        "SELECT rowid_in_fts FROM files WHERE abs_path = ?", (abs_path,)
    )
    row = cur.fetchone()
    if not row:
        return False
    rowid = row[0]
    conn.execute("DELETE FROM memories WHERE rowid = ?", (rowid,))
    conn.execute("DELETE FROM files WHERE abs_path = ?", (abs_path,))
    return True


def sync_incremental(conn):
    on_disk = {}
    for p in walk_memory_files():
        try:
            on_disk[str(p)] = int(p.stat().st_mtime)
        except OSError:
            continue
    in_db = {
        row[0]: row[1]
        for row in conn.execute("SELECT abs_path, mtime FROM files")
    }
    added = updated = deleted = 0
    for abs_path in in_db.keys() - on_disk.keys():
        if delete_path(conn, abs_path):
            deleted += 1
    for abs_path, mtime in on_disk.items():
        prev = in_db.get(abs_path)
        if prev is None:
            if upsert(conn, pathlib.Path(abs_path)) == "inserted":
                added += 1
        elif prev != mtime:
            if upsert(conn, pathlib.Path(abs_path)) == "updated":
                updated += 1
    conn.commit()
    return added, updated, deleted


def rebuild(conn):
    conn.execute("DROP TABLE IF EXISTS memories")
    conn.execute("DROP TABLE IF EXISTS files")
    conn.executescript(SCHEMA_SQL)
    count = 0
    for p in walk_memory_files():
        if upsert(conn, p) == "inserted":
            count += 1
    conn.commit()
    return count


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--rebuild", action="store_true", help="drop and rebuild from scratch"
    )
    parser.add_argument(
        "--file", help="upsert/delete a single file (used by PostToolUse hook)"
    )
    parser.add_argument("--quiet", action="store_true", help="no stdout")
    args = parser.parse_args()

    conn = open_db()
    try:
        if args.rebuild:
            count = rebuild(conn)
            if not args.quiet:
                print(f"rebuilt: {count} memories indexed at {DB_PATH}")
            return
        if args.file:
            path = pathlib.Path(args.file)
            if not path.exists():
                if delete_path(conn, str(path)):
                    conn.commit()
                    if not args.quiet:
                        print(f"deleted: {path}")
                return
            if not should_index(path):
                if not args.quiet:
                    print(f"skipped (not a memory): {path}")
                return
            result = upsert(conn, path)
            conn.commit()
            if not args.quiet:
                print(f"{result}: {path}")
            return
        added, updated, deleted = sync_incremental(conn)
        if not args.quiet:
            print(f"incremental: +{added} ~{updated} -{deleted}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
