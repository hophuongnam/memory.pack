#!/usr/bin/env bash
# Memory.Pack installer — make the auto-memory engine a real
# `git clone && ./install.sh` app on any macOS/Linux host.
#
#   ./install.sh [--prefix DIR] [--yes] [--with-sdk] [--check]
#   ./install.sh --uninstall [--prefix DIR] [--purge] [--yes]
#
# What it does (all idempotent):
#   1. preflight deps (bash git python3 jq sqlite3 node)
#   2. copy the engine to $PREFIX (no .git, no runtime state, no search.db)
#   3. merge the manifest's hook registrations into ~/.claude/settings.json
#      and set env.MEMORY_PACK_HOME=$PREFIX (foreign hooks/keys untouched)
#   4. append a SCHEMA.md pointer to ~/.claude/CLAUDE.md (once)
#   5. preflight the claude-agent-sdk (replay); --with-sdk installs it
#      engine-local
#   6. build an empty/local FTS5 index (engine-only data model; <1s)
#
# The engine code is already path/host portable (MEMORY_PACK_HOME +
# md5/md5sum shim + portable SDK resolver) — this script does NOT patch
# sources; it only places files and wires settings.json.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_PREFIX="${MEMORY_PACK_HOME:-$HOME/.memory-pack}"
PREFIX="$DEFAULT_PREFIX"
ASSUME_YES=false UNINSTALL=false PURGE=false CHECK_ONLY=false WITH_SDK=false

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    --purge) PURGE=true; shift ;;
    --with-sdk) WITH_SDK=true; shift ;;
    --check) CHECK_ONLY=true; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 1. preflight -----------------------------------------------------
preflight() {
  local d missing=()
  for d in bash git python3 jq sqlite3 node; do
    command -v "$d" >/dev/null 2>&1 || missing+=("$d")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "missing required dependencies: ${missing[*]}"
    warn "install them and re-run (e.g. apt install ${missing[*]} / brew install ${missing[*]})"
    return 1
  fi
  say "preflight OK: bash git python3 jq sqlite3 node all present"
  return 0
}

if $CHECK_ONLY; then preflight; exit $?; fi
preflight || die "dependency preflight failed"

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
SL_LINK="$CLAUDE_DIR/statusline-command.sh"
MANIFEST="$PREFIX/install/hooks.manifest.json"
mkdir -p "$CLAUDE_DIR"

# ---- uninstall --------------------------------------------------------
if $UNINSTALL; then
  if [ -f "$SETTINGS" ]; then
    # Prefer the installed copy; fall back to the checkout's own so a purged
    # PREFIX (`rm -rf ~/.memory-pack` first) still unwires settings.json
    # instead of dying with 13 dangling hook registrations.
    MS="$PREFIX/install/merge-settings.sh"; MF="$MANIFEST"
    if [ ! -f "$MS" ]; then
      MS="$SELF_DIR/install/merge-settings.sh"; MF="$SELF_DIR/install/hooks.manifest.json"
    fi
    [ -f "$MS" ] || die "merge-settings.sh not found at $PREFIX or $SELF_DIR"
    tmp="$(mktemp)"
    "$MS" --prefix "$PREFIX" --manifest "$MF" --statusline "$SL_LINK" --uninstall < "$SETTINGS" > "$tmp"
    jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "uninstall produced invalid JSON — settings.json untouched"; }
    mv "$tmp" "$SETTINGS"
    say "removed Memory.Pack hooks + env.MEMORY_PACK_HOME + .statusLine from $SETTINGS"
  fi
  # remove the statusline symlink only if it is ours (points into $PREFIX)
  if [ -L "$SL_LINK" ]; then
    case "$(readlink "$SL_LINK")" in
      "$PREFIX"/*) rm -f "$SL_LINK"; say "removed statusline symlink $SL_LINK" ;;
    esac
  fi
  # remove engine skill symlinks only if they are ours (point into $PREFIX)
  if [ -d "$CLAUDE_DIR/skills" ]; then
    for sl in "$CLAUDE_DIR"/skills/*; do
      [ -L "$sl" ] || continue
      case "$(readlink "$sl")" in
        "$PREFIX"/skills/*) rm -f "$sl"; say "removed skill symlink $sl" ;;
      esac
    done
  fi
  if $PURGE; then rm -rf "$PREFIX"; say "purged engine dir $PREFIX"; fi
  say "uninstall complete."
  exit 0
fi

# ---- 2. place engine --------------------------------------------------
# The in-place guard compares CANONICAL paths but only for the comparison:
# the raw string compare let a trailing slash, relative path, or symlinked
# prefix through, and rsync src==dest with a delete pass then removed .git
# from the SOURCE checkout. PREFIX itself stays exactly as the user gave it
# (wiring must be byte-stable across install/re-install/uninstall — on
# macOS /var is a symlink to /private/var, so rewriting PREFIX to its real
# path would flip every settings.json entry between runs). A nonexistent
# PREFIX can't be the (existing) checkout, so raw is fine then.
PREFIX_REAL="$PREFIX"
if [ -d "$PREFIX" ]; then PREFIX_REAL="$(cd "$PREFIX" && pwd -P)"; fi
[ "$SELF_DIR" != "$PREFIX_REAL" ] || die "refuse to install onto the source checkout itself"
say "installing engine -> $PREFIX"
mkdir -p "$PREFIX"
# One exclusion list drives BOTH rsync and the tar fallback (hand-duplicated
# lists are the drift surface invariant #5 warns about). Semantics: these
# names are excluded from the TRANSFER and — because rsync deletes with
# plain --delete, NOT --delete-excluded — PROTECTED from deletion at the
# destination. --delete-excluded deleted every excluded name AT $PREFIX on
# re-install: all projects' live .boot-context-*/.skip-replay-* (silent
# amnesia on every upgrade of a GNU-rsync host) and, via implied --delete,
# the dest-only node_modules/ from --with-sdk. Stale engine files are still
# cleaned (--delete covers non-excluded names). node_modules/package*.json
# and the machine-local personal files (.mcp.json, .claude, .superpowers,
# vibeCodingMethod) never exist in a clean checkout but are listed so a
# dev-machine install neither ships them nor deletes them at PREFIX.
EXCL_NAMES=(
  '.git' '.worktrees' '.DS_Store'
  '__pycache__' '*.pyc'
  'index/search.db' 'index/search.db-*'
  '.boot-context-*' '.boot-marker-*'
  '.replay-*' '.skip-replay-*'
  '.statusline-clock-*'
  'statusline-token-rate.log'
  'node_modules' 'package.json' 'package-lock.json'
  '.mcp.json' '.claude' '.superpowers' 'vibeCodingMethod'
)
EXCL=(); TAR_EXCL=()
for n in "${EXCL_NAMES[@]}"; do EXCL+=(--exclude "$n"); TAR_EXCL+=("--exclude=$n"); done
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete "${EXCL[@]}" "$SELF_DIR"/ "$PREFIX"/
else
  # tar-pipe fallback (rsync absent on minimal hosts; no stale-file cleanup)
  ( cd "$SELF_DIR" && tar "${TAR_EXCL[@]}" -cf - . ) \
    | ( cd "$PREFIX" && tar -xf - )
fi
chmod +x "$PREFIX"/hooks/*.sh "$PREFIX"/hooks/*.mjs "$PREFIX"/index/*.py \
         "$PREFIX"/install/*.sh "$PREFIX"/install.sh "$PREFIX"/statusline-command.sh 2>/dev/null || true
[ -f "$PREFIX/hooks/_lib.sh" ] && [ -f "$MANIFEST" ] || die "engine copy incomplete at $PREFIX"

# ---- statusline symlink (idempotent, foreign-safe) -------------------
# ~/.claude/statusline-command.sh -> $PREFIX/statusline-command.sh, so
# settings.json statusLine.command stays a stable host-independent path.
# A pre-existing REAL file there (a user's own statusline) is never
# clobbered; in that case we also skip wiring .statusLine.
SL_SRC="$PREFIX/statusline-command.sh"
SL_MERGE=()
if [ ! -f "$SL_SRC" ]; then
  warn "statusline-command.sh missing from engine ($SL_SRC) — statusLine not wired"
elif [ -e "$SL_LINK" ] && [ ! -L "$SL_LINK" ]; then
  warn "$SL_LINK is a real file (not our symlink) — left untouched; statusLine not wired (remove it + re-run to enable)"
else
  ln -sfn "$SL_SRC" "$SL_LINK"
  SL_MERGE=(--statusline "$SL_LINK")
  say "linked statusline: $SL_LINK -> $SL_SRC"
fi

# ---- skills symlinks (idempotent, foreign-safe) ---------------------
# ~/.claude/skills/<name> -> $PREFIX/skills/<name> for each engine skill,
# so the repo OWNS them (version-controlled) and edits go live without a
# reinstall — same trick as the statusline. A pre-existing REAL dir of the
# same name (a user's own skill) is never clobbered. CC follows these
# symlinks during skill discovery (verified CC 2.1.177).
if [ -d "$PREFIX/skills" ]; then
  mkdir -p "$CLAUDE_DIR/skills"
  for skdir in "$PREFIX"/skills/*/; do
    [ -d "$skdir" ] || continue
    name="$(basename "$skdir")"
    link="$CLAUDE_DIR/skills/$name"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      warn "$link is a real dir (not our symlink) — left untouched; skill '$name' not linked"
    else
      ln -sfn "$PREFIX/skills/$name" "$link"
      say "linked skill: $link -> $PREFIX/skills/$name"
    fi
  done
fi

# ---- 3. merge settings.json ------------------------------------------
# -s not -f: a 0-byte settings.json (crash-truncated) must be healed like
# an absent one, or jq emits nothing and the merge dies half-wired.
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
[ -f "$SETTINGS.mp-bak" ] || cp "$SETTINGS" "$SETTINGS.mp-bak"   # one-time pristine backup
tmp="$(mktemp)"
"$PREFIX/install/merge-settings.sh" --prefix "$PREFIX" --manifest "$MANIFEST" "${SL_MERGE[@]+"${SL_MERGE[@]}"}" < "$SETTINGS" > "$tmp"
jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "merge produced invalid JSON — $SETTINGS untouched (backup: $SETTINGS.mp-bak)"; }
mv "$tmp" "$SETTINGS"
say "merged $(jq '.entries|length' "$MANIFEST") Memory.Pack hooks + env.MEMORY_PACK_HOME${SL_MERGE[0]:+ + .statusLine} into $SETTINGS (backup: $SETTINGS.mp-bak)"

# ---- 4. CLAUDE.md pointer (idempotent) -------------------------------
PTR="See \`$PREFIX/SCHEMA.md\` for the canonical auto-memory schema (Memory.Pack)."
if [ ! -f "$CLAUDE_MD" ] || ! grep -qF "$PREFIX/SCHEMA.md" "$CLAUDE_MD"; then
  { [ -f "$CLAUDE_MD" ] && echo; echo "$PTR"; } >> "$CLAUDE_MD"
  say "appended SCHEMA.md pointer to $CLAUDE_MD"
else
  say "CLAUDE.md pointer already present"
fi

# ---- 5. claude-agent-sdk preflight (replay) --------------------------
SDK_SPEC="$(MEMORY_PACK_HOME="$PREFIX" node -e \
  'import("'"$PREFIX"'/hooks/_lib.mjs").then(m=>console.log(m.resolveSdkSpecifier())).catch(()=>process.exit(3))' 2>/dev/null || true)"
sdk_ok=false
if [ -n "$SDK_SPEC" ] && [ "${SDK_SPEC#/}" != "$SDK_SPEC" ] && [ -f "$SDK_SPEC" ]; then
  sdk_ok=true
elif MEMORY_PACK_HOME="$PREFIX" node --input-type=module \
     -e 'await import("@anthropic-ai/claude-agent-sdk/sdk.mjs")' >/dev/null 2>&1; then
  # literal specifier: a trailing S=… was argv (not env), so the probe
  # imported undefined and this branch could never succeed
  sdk_ok=true
fi
if ! $sdk_ok && $WITH_SDK && command -v npm >/dev/null 2>&1; then
  say "installing @anthropic-ai/claude-agent-sdk engine-local (--with-sdk)"
  ( cd "$PREFIX" && npm install --silent --no-audit --no-fund @anthropic-ai/claude-agent-sdk >/dev/null 2>&1 ) \
    && sdk_ok=true || warn "engine-local SDK install failed — install it manually"
fi
if $sdk_ok; then say "claude-agent-sdk resolves (replay enabled)"
else warn "claude-agent-sdk NOT found — replay/boot-context will no-op until you either:
     npm i -g @anthropic-ai/claude-agent-sdk   |   re-run with --with-sdk   |   export CLAUDE_AGENT_SDK=/path/to/sdk.mjs
   (index + search + memory hooks work without it)"; fi

# ---- 6. bootstrap the FTS5 index (engine-only data model) ------------
say "building FTS5 index from $HOME/.claude/projects (engine-only; empty is fine)"
MEMORY_PACK_HOME="$PREFIX" python3 "$PREFIX/index/index-memories.py" --rebuild || \
  warn "index build reported an issue — search-memories.py --rebuild can be re-run anytime"

say "done. Memory.Pack installed at $PREFIX"
say "open a new Claude Code session to load the hooks. Uninstall: $PREFIX/install.sh --uninstall"
say "  Tip: install a Nerd Font (https://www.nerdfonts.com/) for the icon-rich statusline."
