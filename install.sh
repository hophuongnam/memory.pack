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
#   3. merge the 12 hook registrations into ~/.claude/settings.json and set
#      env.MEMORY_PACK_HOME=$PREFIX  (foreign hooks/keys untouched; backup)
#   4. append a SCHEMA.md pointer to ~/.claude/CLAUDE.md (once)
#   5. preflight the claude-agent-sdk (replay); --with-sdk installs it
#      engine-local
#   6. build an empty/local FTS5 index (engine-only data model; <1s)
#
# The engine code is already path/host portable (MEMORY_PACK_HOME +
# md5/md5sum shim + portable SDK resolver) — this script does NOT patch
# sources; it only places files and wires settings.json.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    [ -f "$PREFIX/install/merge-settings.sh" ] || die "engine not found at $PREFIX (need merge-settings.sh)"
    tmp="$(mktemp)"
    "$PREFIX/install/merge-settings.sh" --prefix "$PREFIX" --manifest "$MANIFEST" --statusline "$SL_LINK" --uninstall < "$SETTINGS" > "$tmp"
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
[ "$SELF_DIR" != "$PREFIX" ] || die "refuse to install onto the source checkout itself"
say "installing engine -> $PREFIX"
mkdir -p "$PREFIX"
EXCL=(
  --exclude '.git' --exclude '.worktrees' --exclude '.DS_Store'
  --exclude '__pycache__' --exclude '*.pyc'
  --exclude 'index/search.db' --exclude 'index/search.db-*'
  --exclude '.boot-context-*' --exclude '.boot-marker-*'
  --exclude '.replay-*' --exclude '.skip-replay-*'
  --exclude '.statusline-clock-*'
  --exclude 'statusline-token-rate.log'
)
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete-excluded "${EXCL[@]}" "$SELF_DIR"/ "$PREFIX"/
else
  # tar-pipe fallback (rsync absent on minimal hosts)
  ( cd "$SELF_DIR" && tar --exclude='.git' --exclude='.worktrees' \
      --exclude='__pycache__' --exclude='*.pyc' --exclude='.DS_Store' \
      --exclude='index/search.db' --exclude='index/search.db-*' \
      --exclude='.boot-context-*' --exclude='.boot-marker-*' \
      --exclude='.replay-*' --exclude='.skip-replay-*' \
      --exclude='.statusline-clock-*' \
      --exclude='statusline-token-rate.log' -cf - . ) \
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
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
[ -f "$SETTINGS.mp-bak" ] || cp "$SETTINGS" "$SETTINGS.mp-bak"   # one-time pristine backup
tmp="$(mktemp)"
"$PREFIX/install/merge-settings.sh" --prefix "$PREFIX" --manifest "$MANIFEST" "${SL_MERGE[@]+"${SL_MERGE[@]}"}" < "$SETTINGS" > "$tmp"
jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "merge produced invalid JSON — $SETTINGS untouched (backup: $SETTINGS.mp-bak)"; }
mv "$tmp" "$SETTINGS"
say "merged 12 Memory.Pack hooks + env.MEMORY_PACK_HOME${SL_MERGE[0]:+ + .statusLine} into $SETTINGS (backup: $SETTINGS.mp-bak)"

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
     -e 'await import(process.env.S)' S="@anthropic-ai/claude-agent-sdk/sdk.mjs" >/dev/null 2>&1; then
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
