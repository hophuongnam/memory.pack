# shellcheck shell=bash
# Memory.Pack shared shell library. Sourced by hooks (via
# `. "$SCRIPT_DIR/_lib.sh"`); never executed as a hook itself, hence the
# leading-underscore name and no shebang / no +x.

# _mp_hash: read stdin, print the first 8 hex chars of its MD5 digest.
#
# Value-preserving, portable replacement for the legacy expression
#   printf '%s' "$KEY" | md5 | head -c 8
# macOS `md5` prints the digest alone ("<hex>\n"); GNU `md5sum` prints
# "<hex>  -\n". `head -c 8` yields the same first 8 hex chars from either,
# and MD5 is tool-independent, so the derived PROJECT_HASH is byte-identical
# across the macOS/Linux split — existing .boot-context-<hash> and
# .skip-replay-<hash> sentinels (and the independent statusline derivation)
# stay valid after the swap.
#
# Fails LOUD (stderr + return 1) when no MD5 tool exists rather than
# emitting an empty hash: a silent empty PROJECT_HASH would mis-scope every
# boot-context/sentinel filename, which is exactly the silent-amnesia class
# this shim exists to eliminate.
_mp_hash() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum | head -c 8
  elif command -v md5 >/dev/null 2>&1; then
    md5 | head -c 8
  else
    echo "memory-pack: no md5sum or md5 binary found for PROJECT_HASH derivation" >&2
    return 1
  fi
}
