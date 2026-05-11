#!/bin/bash
# SessionEnd hook — full incremental reconcile of the auto-memory FTS5 index.
# Catches out-of-band changes the per-file PostToolUse hook can't see:
#   * `mv` to/from archive/ (e.g. via /memory-lint)
#   * git restore / git checkout overwrites
#   * direct filesystem edits outside Claude
#
# Backgrounded so SessionEnd's 5s budget is never the bottleneck. The
# incremental walk over ~700 files normally finishes in under 100ms, but
# we don't want a slow disk to delay session shutdown.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INDEXER="$SCRIPT_DIR/../index/index-memories.py"

nohup python3 "$INDEXER" --quiet \
  >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0
