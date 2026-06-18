#!/bin/bash
# TDD: install.sh end-to-end into a throwaway HOME. Proves preflight,
# engine placement (no .git / no search.db shipped), settings.json merge,
# CLAUDE.md pointer, empty-index bootstrap, idempotency, and uninstall —
# all without touching the real ~/.claude or any shared host.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"            # the engine checkout under test
INSTALL="$SRC/install.sh"

fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

[ -f "$INSTALL" ] || { echo "FAIL  install.sh missing ($INSTALL)"; exit 1; }

SBX="$(mktemp -d)"; trap 'rm -rf "$SBX"' EXIT
FH="$SBX/home"; PREFIX="$FH/.memory-pack"
mkdir -p "$FH/.claude/projects/-x-demo/memory"
printf '%s\n' '# CLAUDE.md' 'existing user content' > "$FH/.claude/CLAUDE.md"
# minimal pre-existing settings.json with a foreign hook (must survive)
cat > "$FH/.claude/settings.json" <<'JSON'
{ "theme": "dark",
  "hooks": { "PreToolUse": [ { "hooks": [ { "type":"command", "command":"/foreign/x.sh" } ] } ] } }
JSON
# a demo memory so the index has something to index
cat > "$FH/.claude/projects/-x-demo/memory/feedback_demo.md" <<'MD'
---
name: feedback_demo
description: demo memory for install test
metadata:
  type: feedback
---
Demo body.
MD

run() { HOME="$FH" bash "$INSTALL" "$@"; }
SL_LINK="$FH/.claude/statusline-command.sh"

# --- preflight-only mode ---
run --check >/dev/null 2>&1 && ok "preflight (--check) passes with full deps" \
  || bad "preflight passes with full deps"
if env -i PATH=/nonexistent HOME="$FH" bash "$INSTALL" --check >/dev/null 2>&1; then
  bad "preflight fails loud when deps missing" "exited 0 with empty PATH"
else
  ok "preflight fails loud when deps missing"
fi

# --- install ---
if run --prefix "$PREFIX" --yes >"$SBX/log" 2>&1; then ok "install exits 0"
else bad "install exits 0" "$(tail -3 "$SBX/log")"; fi

[ -f "$PREFIX/hooks/_lib.sh" ] && [ -f "$PREFIX/hooks/boot-inject.sh" ] && [ -f "$PREFIX/index/index-memories.py" ] \
  && ok "engine files placed at prefix" || bad "engine files placed at prefix"
# every wired hook must actually LAND at PREFIX executable — a hook merged into
# settings.json but not copied (or not +x) is a silent no-op (the failure class
# boot-catchup itself guards against). Generic over the manifest so a new entry
# can't be wired-but-missing.
missing=""
for sc in $(jq -r '.entries[].script' "$SRC/install/hooks.manifest.json" | sort -u); do
  [ -x "$PREFIX/hooks/$sc" ] || missing="$missing $sc"
done
[ -z "$missing" ] && ok "all manifest hook scripts present + executable at prefix" \
  || bad "all manifest hook scripts present + executable at prefix" "missing/non-exec:$missing"
[ ! -e "$PREFIX/.git" ] && ok "no .git shipped" || bad "no .git shipped"
[ ! -e "$PREFIX/index/search.db" ] || \
  { [ -f "$PREFIX/index/search.db" ] && [ ! -s "$PREFIX/index/search.db.SHIPPED" ]; }
if find "$PREFIX" -name 'search.db' -path '*/index/*' -newer "$SRC/install.sh" >/dev/null 2>&1 \
   && [ -f "$PREFIX/index/search.db" ]; then ok "search.db is freshly built, not shipped"; else
   [ -f "$PREFIX/index/search.db" ] && ok "search.db is freshly built, not shipped" || bad "search.db built"; fi

# settings merged: 13 MP entries w/ prefix, foreign survives, env set
mp=$(jq '[.hooks[]?[]?.hooks[]?.command//empty|select(startswith("'"$PREFIX"'/hooks/"))]|length' "$FH/.claude/settings.json")
[ "$mp" = "13" ] && ok "settings.json: 13 MP entries with prefix" || bad "13 MP entries" "got $mp"
jq -e '.hooks.PreToolUse[]?.hooks[]?|select(.command=="/foreign/x.sh")' "$FH/.claude/settings.json" >/dev/null \
  && ok "settings.json: foreign hook survived" || bad "foreign hook survived"
jq -e '.env.MEMORY_PACK_HOME=="'"$PREFIX"'" and .theme=="dark"' "$FH/.claude/settings.json" >/dev/null \
  && ok "settings.json: env + unrelated keys ok" || bad "env + unrelated keys ok"
[ -f "$FH/.claude/settings.json.mp-bak" ] && ok "settings.json backed up" || bad "settings.json backed up"

# statusline: ~/.claude/statusline-command.sh symlink -> PREFIX, target exec;
# settings.json .statusLine.command points at the symlink
{ [ -L "$SL_LINK" ] && [ "$(readlink "$SL_LINK")" = "$PREFIX/statusline-command.sh" ] && [ -x "$SL_LINK" ]; } \
  && ok "statusline: symlink -> PREFIX, target executable" \
  || bad "statusline: symlink -> PREFIX, target executable" "readlink=$(readlink "$SL_LINK" 2>/dev/null)"
jq -e --arg c "bash $SL_LINK" '.statusLine.type=="command" and .statusLine.command==$c' "$FH/.claude/settings.json" >/dev/null \
  && ok "statusline: settings.json .statusLine.command set to symlink" || bad "statusline: settings.json .statusLine set"

# skills: ~/.claude/skills/<name> symlink -> PREFIX/skills/<name>, SKILL.md
# readable through it (engine owns the skills in-repo, symlinked out)
for sk in memory-search memory-lint; do
  L="$FH/.claude/skills/$sk"
  { [ -L "$L" ] && [ "$(readlink "$L")" = "$PREFIX/skills/$sk" ] && [ -f "$L/SKILL.md" ]; } \
    && ok "skill: $sk symlink -> PREFIX/skills/$sk, SKILL.md readable" \
    || bad "skill: $sk symlink -> PREFIX/skills/$sk" "readlink=$(readlink "$L" 2>/dev/null)"
done

# CLAUDE.md pointer appended, original content kept
grep -q "$PREFIX/SCHEMA.md" "$FH/.claude/CLAUDE.md" && grep -q 'existing user content' "$FH/.claude/CLAUDE.md" \
  && ok "CLAUDE.md pointer appended, content preserved" || bad "CLAUDE.md pointer appended"

# index built (empty-data model still produces a db; demo memory indexed)
[ -f "$PREFIX/index/search.db" ] && \
  MEMORY_PACK_HOME="$PREFIX" python3 "$PREFIX/index/search-memories.py" demo --json 2>/dev/null | jq -e 'length>=1' >/dev/null \
  && ok "index bootstrapped and queryable" || bad "index bootstrapped and queryable"

# --- idempotent ---
run --prefix "$PREFIX" --yes >/dev/null 2>&1
mp2=$(jq '[.hooks[]?[]?.hooks[]?.command//empty|select(startswith("'"$PREFIX"'/hooks/"))]|length' "$FH/.claude/settings.json")
[ "$mp2" = "13" ] && ok "idempotent re-install (still 13, not 26)" || bad "idempotent re-install" "got $mp2"
{ [ -L "$SL_LINK" ] && [ "$(readlink "$SL_LINK")" = "$PREFIX/statusline-command.sh" ]; } \
  && ok "statusline: symlink stable after idempotent re-install" || bad "statusline: symlink stable on re-install"
{ [ -L "$FH/.claude/skills/memory-search" ] && [ "$(readlink "$FH/.claude/skills/memory-search")" = "$PREFIX/skills/memory-search" ]; } \
  && ok "skill: symlink stable after idempotent re-install" || bad "skill: symlink stable on re-install"

# --- uninstall ---
run --prefix "$PREFIX" --uninstall --yes >/dev/null 2>&1
mp3=$(jq '[.hooks[]?[]?.hooks[]?.command//empty|select(startswith("'"$PREFIX"'/hooks/"))]|length' "$FH/.claude/settings.json")
{ [ "$mp3" = "0" ] && jq -e '(.env|has("MEMORY_PACK_HOME")|not)' "$FH/.claude/settings.json" >/dev/null \
  && jq -e '.hooks.PreToolUse[]?.hooks[]?|select(.command=="/foreign/x.sh")' "$FH/.claude/settings.json" >/dev/null; } \
  && ok "uninstall reverses settings, foreign intact" || bad "uninstall reverses settings" "mp=$mp3"
{ [ ! -e "$SL_LINK" ] && jq -e 'has("statusLine")|not' "$FH/.claude/settings.json" >/dev/null; } \
  && ok "statusline: uninstall removes symlink + .statusLine" || bad "statusline: uninstall removes symlink + .statusLine"
{ [ ! -e "$FH/.claude/skills/memory-search" ] && [ ! -e "$FH/.claude/skills/memory-lint" ]; } \
  && ok "skill: uninstall removes symlinks" || bad "skill: uninstall removes symlinks"

# --- foreign-safety: a REAL regular file at ~/.claude/statusline-command.sh
#     (a user's own, not our symlink) must NEVER be clobbered ---
SBX2="$(mktemp -d)"; FH2="$SBX2/home"; PFX2="$FH2/.memory-pack"
mkdir -p "$FH2/.claude"
printf 'echo MINE\n' > "$FH2/.claude/statusline-command.sh"
# a pre-existing REAL skill dir of the same name (a user's own) must NOT be clobbered
mkdir -p "$FH2/.claude/skills/memory-search"
printf -- '---\nname: mine\ndescription: my own\n---\nMINE SKILL BODY\n' > "$FH2/.claude/skills/memory-search/SKILL.md"
echo '{}' > "$FH2/.claude/settings.json"
HOME="$FH2" bash "$INSTALL" --prefix "$PFX2" --yes >/dev/null 2>&1; rc2=$?
# install must NOT abort on a pre-existing real skill dir — without the
# foreign-safe guard, `ln -sfn` over a real dir fails and `set -e` kills
# the whole install (this is the load-bearing half of foreign-safety).
[ "$rc2" = "0" ] \
  && ok "install exits 0 despite pre-existing real skill dir (no set -e abort)" \
  || bad "install exits 0 despite pre-existing real skill dir" "rc=$rc2"
{ [ ! -L "$FH2/.claude/statusline-command.sh" ] && grep -q 'echo MINE' "$FH2/.claude/statusline-command.sh"; } \
  && ok "statusline: pre-existing real file NOT clobbered (foreign-safe)" \
  || bad "statusline: pre-existing real file NOT clobbered (foreign-safe)"
# not clobbered AND not polluted: BSD `ln -sfn SRC realdir` exits 0 but
# drops a stray nested symlink inside the user's dir — the guard must
# prevent that too, so assert zero symlinks under the real dir.
{ [ ! -L "$FH2/.claude/skills/memory-search" ] && grep -q 'MINE SKILL BODY' "$FH2/.claude/skills/memory-search/SKILL.md" \
  && ! find "$FH2/.claude/skills/memory-search" -type l | grep -q .; } \
  && ok "skill: pre-existing real dir NOT clobbered or polluted (foreign-safe)" \
  || bad "skill: pre-existing real dir NOT clobbered or polluted (foreign-safe)"
rm -rf "$SBX2"

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fail FAILED"; exit 1; fi
