#!/usr/bin/env python3
"""Canonicalize memory cross-reference links and audit index/disk consistency.

Resolves every `](...slug.md)` link by where `slug.md` actually lives, so a
move to or from `archive/` cannot leave a stale path. Idempotent: run it as
many times as you like. Used by /memory-lint --archive after moving files.

  python3 memory-links.py <memory-dir> [--check]

`--check` reports without writing. Exit 1 if unresolved links remain.
Direct file writes on purpose — no Claude Read/Write hook fires, so recall
counters and the archive-resurrect trap stay out of the way.
"""
import os, re, sys

LINK = re.compile(r"\]\((?:\.\./|archive/)?([A-Za-z0-9_][A-Za-z0-9_.-]*\.md)\)")
# ponytail: hook-maintained, not memories — scanned for nothing, never rewritten.
SKIP = {"SESSIONS.md", "sessions.log.md", "PENDING_MEMORIES.md"}


def canonicalize(mem_dir, check=False):
    arc_dir = os.path.join(mem_dir, "archive")
    active = {f for f in os.listdir(mem_dir) if f.endswith(".md") and f not in SKIP}
    archived = {f for f in os.listdir(arc_dir) if f.endswith(".md")} if os.path.isdir(arc_dir) else set()

    rewritten, unresolved, placeholders = [], [], []

    def fix(path, name, in_archive):
        with open(path, encoding="utf-8") as fh:
            text = fh.read()

        def repl(m):
            slug = m.group(1)
            if slug in active:
                dest = f"]({'../' if in_archive else ''}{slug})"
            elif slug in archived:
                dest = f"]({slug})" if in_archive else f"](archive/{slug})"
            else:
                # ponytail: real slugs always carry a `_` or `-`; bare `X.md` /
                # `slug.md` in prose is a doc placeholder, not rot.
                bare = slug[:-3]
                (placeholders if "_" not in bare and "-" not in bare
                 else unresolved).append((name, slug))
                return m.group(0)
            return dest

        new = LINK.sub(repl, text)
        if new != text:
            rewritten.append(name)
            if not check:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(new)

    for f in sorted(active):
        fix(os.path.join(mem_dir, f), f, False)
    for f in sorted(archived):
        fix(os.path.join(arc_dir, f), f"archive/{f}", True)

    # index <-> disk reconcile
    index = os.path.join(mem_dir, "MEMORY.md")
    indexed = set()
    if os.path.isfile(index):
        for line in open(index, encoding="utf-8"):
            if line.lstrip().startswith("- "):
                m = LINK.search(line)
                if m:
                    indexed.add(m.group(1))
    memories = active - {"MEMORY.md"}
    return {
        "rewritten": rewritten,
        "unresolved": unresolved,
        "placeholders": placeholders,
        "orphans": sorted(memories - indexed),
        "dead_entries": sorted(indexed - memories - archived),
        "active": len(memories),
        "archived": len(archived),
    }


def selftest():
    import tempfile, shutil
    d = tempfile.mkdtemp()
    try:
        os.makedirs(os.path.join(d, "archive"))
        w = lambda p, t: open(os.path.join(d, p), "w").write(t)
        w("a.md", "see [b](archive/nope_gone.md) and [c](archive/c.md) and [gone](x.md)\n")
        w("archive/c.md", "back to [a](c_wrong.md) and [a](a.md) and [d](archive/d.md)\n")
        w("archive/d.md", "leaf\n")
        w("MEMORY.md", "- [a](a.md)\n- [dead](dead.md)\n")
        r = canonicalize(d)
        body_a = open(os.path.join(d, "a.md")).read()
        assert "](c.md)" not in body_a and "](archive/c.md)" in body_a, body_a
        body_c = open(os.path.join(d, "archive/c.md")).read()
        assert "](../a.md)" in body_c, body_c
        assert "](d.md)" in body_c and "](archive/d.md)" not in body_c, body_c
        assert ("a.md", "nope_gone.md") in r["unresolved"]
        assert ("archive/c.md", "c_wrong.md") in r["unresolved"]
        assert ("a.md", "x.md") in r["placeholders"]
        assert r["dead_entries"] == ["dead.md"] and r["orphans"] == []
        before = open(os.path.join(d, "archive/c.md")).read()
        canonicalize(d)  # idempotent
        assert open(os.path.join(d, "archive/c.md")).read() == before
        print("selftest ok")
    finally:
        shutil.rmtree(d)


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--selftest" in args:
        selftest(); sys.exit(0)
    if not args:
        sys.exit(__doc__)
    r = canonicalize(args[0], check="--check" in args)
    verb = "would rewrite" if "--check" in args else "rewrote"
    print(f"{verb} {len(r['rewritten'])} file(s); {r['active']} active, {r['archived']} archived")
    for name, slug in r["unresolved"]:
        print(f"UNRESOLVED {name} -> {slug}")
    if r["placeholders"]:
        print(f"(skipped {len(r['placeholders'])} doc placeholder link(s))")
    for o in r["orphans"]:
        print(f"ORPHAN (on disk, not in MEMORY.md) {o}")
    for dnd in r["dead_entries"]:
        print(f"DEAD INDEX ENTRY (no such file) {dnd}")
    sys.exit(1 if r["unresolved"] or r["orphans"] or r["dead_entries"] else 0)
