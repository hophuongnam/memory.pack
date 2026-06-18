#!/bin/bash
# PostToolUse "catch-up" injector — closes the mid-turn boot-context gap.
#
# boot context is injected on SessionStart (polls 4s) and UserPromptSubmit
# (polls 9s). When the prior session's detached replay outlasts BOTH windows,
# the first (long) turn runs blind: `.boot-context-<hash>` lands on disk
# mid-turn but nothing injects it until the NEXT user prompt — too late for
# the turn already in flight. PostToolUse fires between tool calls, so this
# (matcher-less → every tool) hook catches the file the moment it appears and
# hands off to boot-inject.sh, which emits it as additionalContext. CC injects
# a PostToolUse hook's additionalContext into the model on its next request
# within the SAME turn (verified in bundle 2.1.181 — see reference memory
# cc_posttooluse_additionalcontext).
#
# SHARED-DIR SAFETY (load-bearing): hooks are wired by ABSOLUTE path to one
# shared hooks/ dir, and EVERY project writes its `.boot-context-<hash>` here.
# This hook fires in every project's session, so it must act ONLY on THIS
# session's own hash (resolved from stdin's transcript_path, exactly like
# boot-inject). Handing a FOREIGN project's unconsumed leftover to boot-inject
# would make it emit "[No boot context available]" AND flip this project's
# marker to "none" on every tool call for the whole window that file sits
# there. test_boot_catchup pins this (Case D + the foreign-marker e2e case).
d=${0%/*}

# Forkless fast-reject: if the shared dir has NO live (non -last-) context at
# all, nothing can be ours → exit before reading stdin or forking. (Builtin
# glob + case only.) When foreign leftovers exist we fall through to the
# per-session hash check below.
# ponytail: the stdin-parse + hash-resolve below runs per tool call whenever
# ANY live context (incl. another project's) is present — the unavoidable cost
# of per-session correctness in a shared dir (our hash isn't known without
# stdin). One jq fork; comparable to memory-recall's per-Read footprint, and
# tool calls are seconds-scale so it's marginal. Upgrade path if it ever
# bites: cache our resolved hash in a per-session sentinel after first run.
_live=0
for f in "$d"/.boot-context-*; do
  case "$f" in *-last-*) continue ;; esac   # carry-forward snapshot, not fresh
  [ -e "$f" ] && { _live=1; break; }
done
[ "$_live" = 1 ] || exit 0

INPUT=$(cat)
. "$d/_lib.sh" || exit 0
# One jq fork (snake/camel tolerant), mirroring boot-inject.sh's extraction.
IFS=$'\t' read -r _tr _pdir _cwd <<<"$(printf '%s' "$INPUT" | jq -r '[.transcript_path // .transcriptPath // "", .workspace.project_dir // .workspace.projectDir // "", .cwd // ""] | @tsv')"
_key=$(_mp_resolve_project_key "$_tr" "${_pdir:-${_cwd:-$PWD}}")
_hash=$(printf '%s' "$_key" | _mp_hash)

# Only OUR live context triggers the (one-time per turn) hand-off. exec, not
# call: re-feed the unread stdin so boot-inject reads the PostToolUse payload
# fresh and resolves the same dir/hash, then falls through its consume →
# archive → mv → emit path (EVENT=PostToolUse). Once it mv's the live file to
# .boot-context-last-<hash>, this gate is dry for us on every later tool call.
[ -n "$_hash" ] && [ -e "$d/.boot-context-$_hash" ] || exit 0
exec "$d/boot-inject.sh" <<<"$INPUT"
