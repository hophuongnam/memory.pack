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
# preflight must fail LOUD when a dep is missing. A stub PATH holding ONLY
# bash+dirname lets install.sh itself run while git/jq/... are absent — the
# old `env -i PATH=/nonexistent` form died at env's bash lookup (exit 127
# before install.sh ever ran), so it passed whatever preflight() did.
STUBBIN="$SBX/stubbin"; mkdir -p "$STUBBIN"
ln -s "$(command -v bash)" "$STUBBIN/bash"
ln -s "$(command -v dirname)" "$STUBBIN/dirname"
PF_OUT=$(env -i PATH="$STUBBIN" HOME="$FH" bash "$INSTALL" --check 2>&1); PF_RC=$?
if [ "$PF_RC" -ne 0 ] && printf '%s' "$PF_OUT" | grep -q 'missing required dependencies'; then
  ok "preflight fails loud when deps missing"
else
  bad "preflight fails loud when deps missing" "rc=$PF_RC out=$(printf '%s' "$PF_OUT" | head -1)"
fi

# --- install ---
touch "$SBX/pre-install-ts"; sleep 1   # freshness anchor for the search.db assert
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
# search.db must be BUILT during install (step 6), never shipped from the
# checkout: strictly newer than the pre-install timestamp. (The old form
# `find … >/dev/null` ok'd on mere existence in BOTH branches — a shipped
# stale db passed as "freshly built".)
if [ -n "$(find "$PREFIX/index/search.db" -newer "$SBX/pre-install-ts" 2>/dev/null)" ]; then
  ok "search.db is freshly built, not shipped"
else
  bad "search.db is freshly built, not shipped" "missing or older than pre-install timestamp"
fi
# SDK bare-import probe must use a literal specifier: `node -e '…' S=value`
# puts S= in argv, not env, so process.env.S was undefined and the probe
# branch could never succeed (false "SDK NOT found" warnings).
grep -q 'await import("@anthropic-ai/claude-agent-sdk/sdk.mjs")' "$INSTALL" \
  && ok "SDK bare-import probe uses a literal specifier" \
  || bad "SDK bare-import probe uses a literal specifier" "dead post-command env assignment still present"

# settings merged: every manifest entry lands w/ prefix, foreign survives, env set.
# Count comes FROM the manifest — it is the canonical registration list, so adding
# a hook there can never leave this assertion pinned to a stale literal.
NHOOKS=$(jq '.entries|length' "$SRC/install/hooks.manifest.json")
mp=$(jq '[.hooks[]?[]?.hooks[]?.command//empty|select(startswith("'"$PREFIX"'/hooks/"))]|length' "$FH/.claude/settings.json")
[ "$mp" = "$NHOOKS" ] && ok "settings.json: all $NHOOKS manifest entries wired with prefix" \
                      || bad "all manifest entries wired" "got $mp, manifest has $NHOOKS"
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

# --- idempotent + upgrade preserves live state at PREFIX ---
# Between-session runtime state (boot contexts, sentinels) and the
# engine-local SDK live at PREFIX on installed hosts. A re-install/upgrade
# must not destroy them: `rsync --delete-excluded` deleted every excluded
# name AT THE DESTINATION (all projects' pending boot contexts +
# carry-forwards + skip sentinels) and, via implied --delete, the
# dest-only node_modules/ — silent amnesia + replay death on every
# `git pull && ./install.sh`. Stale ENGINE files must still be cleaned.
printf 'TITLE: t\n' > "$PREFIX/hooks/.boot-context-cafe1234"
printf 'TITLE: t\n' > "$PREFIX/hooks/.boot-context-last-cafe1234"
: > "$PREFIX/hooks/.skip-replay-cafe1234"
mkdir -p "$PREFIX/node_modules/@anthropic-ai/claude-agent-sdk"
printf 'export {}\n' > "$PREFIX/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"
printf '{}\n' > "$PREFIX/package.json"
: > "$PREFIX/hooks/zz-stale-engine-file.sh"   # not in source → upgrade must clean it
run --prefix "$PREFIX" --yes >/dev/null 2>&1
{ [ -f "$PREFIX/hooks/.boot-context-cafe1234" ] && [ -f "$PREFIX/hooks/.boot-context-last-cafe1234" ] \
  && [ -f "$PREFIX/hooks/.skip-replay-cafe1234" ]; } \
  && ok "re-install preserves live boot-context/sentinel state at PREFIX" \
  || bad "re-install preserves live boot-context/sentinel state at PREFIX"
{ [ -f "$PREFIX/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs" ] && [ -f "$PREFIX/package.json" ]; } \
  && ok "re-install preserves engine-local SDK (node_modules + package.json)" \
  || bad "re-install preserves engine-local SDK (node_modules + package.json)"
[ ! -e "$PREFIX/hooks/zz-stale-engine-file.sh" ] \
  && ok "re-install still cleans stale engine files (--delete)" \
  || bad "re-install still cleans stale engine files (--delete)"
mp2=$(jq '[.hooks[]?[]?.hooks[]?.command//empty|select(startswith("'"$PREFIX"'/hooks/"))]|length' "$FH/.claude/settings.json")
[ "$mp2" = "$NHOOKS" ] && ok "idempotent re-install (still $NHOOKS, not doubled)" \
                       || bad "idempotent re-install" "got $mp2, want $NHOOKS"
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

# --- uninstall works from the checkout even when PREFIX was already purged ---
# `rm -rf ~/.memory-pack` then `./install.sh --uninstall` used to die
# ("engine not found") BEFORE unwiring settings.json, stranding all the dangling
# hook registrations; the fallback to the checkout's own merge-settings.sh
# must unwire them.
PFX4="$FH/.memory-pack2"
run --prefix "$PFX4" --yes >/dev/null 2>&1
rm -rf "$PFX4"
if run --prefix "$PFX4" --uninstall --yes >/dev/null 2>&1; then
  mp4=$(jq '[.hooks[]?[]?.hooks[]?.command//empty|select(startswith("'"$PFX4"'/hooks/"))]|length' "$FH/.claude/settings.json")
  [ "$mp4" = "0" ] && ok "uninstall after purged PREFIX still unwires settings (checkout fallback)" \
    || bad "uninstall after purged PREFIX still unwires settings" "mp=$mp4"
else
  bad "uninstall after purged PREFIX still unwires settings" "exited nonzero (die: engine not found?)"
fi

# --- in-place refusal: any PREFIX resolving to the checkout must die BEFORE
#     rsync. The raw string compare passed trailing-slash / relative /
#     symlinked prefixes, and rsync src==dest with a delete pass then removed
#     .git from the SOURCE checkout. Run against a sacrificial copy. ---
COPY="$SBX/engine-copy"; mkdir -p "$COPY"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude '.git' "$SRC"/ "$COPY"/
else
  cp -R "$SRC"/. "$COPY"/ 2>/dev/null; rm -rf "$COPY/.git"
fi
mkdir -p "$COPY/.git"; printf 'ref: sacrificial\n' > "$COPY/.git/HEAD"
FH3="$SBX/home3"; mkdir -p "$FH3/.claude"; echo '{}' > "$FH3/.claude/settings.json"
ln -s "$COPY" "$SBX/engine-link"
ipfail=""
for P in "$COPY" "$COPY/" "$SBX/engine-link"; do
  if HOME="$FH3" bash "$COPY/install.sh" --prefix "$P" --yes >/dev/null 2>&1; then
    ipfail="$ipfail exit0[$P]"
  fi
  [ -f "$COPY/.git/HEAD" ] || { ipfail="$ipfail gitgone[$P]"; break; }
done
if [ -f "$COPY/.git/HEAD" ]; then
  ( cd "$COPY" && HOME="$FH3" bash ./install.sh --prefix . --yes >/dev/null 2>&1 ) && ipfail="$ipfail exit0[.]"
  [ -f "$COPY/.git/HEAD" ] || ipfail="$ipfail gitgone[.]"
fi
[ -z "$ipfail" ] && ok "in-place install refused (plain, trailing-slash, symlink, relative)" \
  || bad "in-place install refused (plain, trailing-slash, symlink, relative)" "$ipfail"

# --- 0-byte settings.json (crash-truncated) must be healed like absent ---
FH5="$SBX/home5"; mkdir -p "$FH5/.claude"; : > "$FH5/.claude/settings.json"
if HOME="$FH5" bash "$INSTALL" --prefix "$FH5/.mp" --yes >/dev/null 2>&1 \
   && jq -e '.env.MEMORY_PACK_HOME' "$FH5/.claude/settings.json" >/dev/null 2>&1; then
  ok "0-byte settings.json healed to {} and wired"
else
  bad "0-byte settings.json healed to {} and wired" "install died at merge or env missing"
fi

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

# --- invariant #5 pin: every .gitignore pattern is packaging-excluded -------
# Runtime state is never packaged: .gitignore (repo hygiene) and install.sh
# EXCL_NAMES (rsync/tar packaging) must agree. Before this pin, deleting an
# exclude from EXCL_NAMES failed NOTHING — the next install would ship (or,
# pre-Batch-A, delete) live runtime state. Every non-comment .gitignore
# pattern must be covered by some EXCL_NAMES pattern (string-glob match on
# the full pattern or its basename — rsync basename patterns match anywhere).
EXCL_LIST="$(sed -n '/^EXCL_NAMES=(/,/^)/p' "$HERE/../install.sh"   | grep -o "'[^']*'" | tr -d "'")"
[ -n "$EXCL_LIST" ] || bad "EXCL_NAMES array extracted from install.sh" "empty extraction"
while IFS= read -r gi; do
  case "$gi" in ''|'#'*) continue ;; esac
  gi="${gi%/}"                      # trailing dir slash
  gibase="${gi##*/}"                # basename form
  covered=0
  for e in $EXCL_LIST; do
    # shellcheck disable=SC2254 — $e is deliberately a glob
    case "$gi" in $e) covered=1; break ;; esac
    case "$gibase" in $e) covered=1; break ;; esac
  done
  if [ "$covered" = 1 ]; then
    ok "invariant #5: .gitignore '$gi' covered by EXCL_NAMES"
  else
    bad "invariant #5: .gitignore '$gi' covered by EXCL_NAMES" "no matching exclude — install would package/clobber it"
  fi
done < "$HERE/../.gitignore"

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fail FAILED"; exit 1; fi
