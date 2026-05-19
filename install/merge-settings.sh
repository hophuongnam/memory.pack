#!/bin/bash
# Merge Memory.Pack hook registrations into a Claude Code settings.json.
#
#   merge-settings.sh --prefix P --manifest M [--uninstall] < settings.json > new.json
#
# Strategy: STRIP every MP-owned hook (identified by script basename from
# the manifest, ANY prefix — so stale installs are cleaned) then RE-ADD
# from the manifest with command=$PREFIX/hooks/<script>. This makes the
# operation idempotent by construction and doubles as the upgrade path.
# Foreign hooks, null/absent-command entries, and every non-hook top-level
# key are left untouched. Reads stdin, writes stdout (no file I/O here —
# install.sh owns backup/atomic-write).
set -euo pipefail

PREFIX="" MANIFEST="" UNINSTALL=false SL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)   PREFIX="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --statusline) SL="$2"; shift 2 ;;
    --uninstall) UNINSTALL=true; shift ;;
    *) echo "merge-settings.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PREFIX" ]   || { echo "merge-settings.sh: --prefix required" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "merge-settings.sh: manifest not found: $MANIFEST" >&2; exit 2; }

ENTRIES=$(jq -c '.entries' "$MANIFEST")

jq \
  --arg prefix "$PREFIX" \
  --arg sl "$SL" \
  --argjson manifest "$ENTRIES" \
  --argjson uninstall "$UNINSTALL" '
  ($manifest | map(.script) | unique) as $owned

  # ---- STRIP all MP-owned hooks (any prefix), null-command safe ----
  | .hooks = (
      (.hooks // {})
      | with_entries(
          .value |= (
            map(
              .hooks = ((.hooks // []) | map(
                select(
                  (((.command // "") | tostring | split("/") | last)) as $b
                  | ($owned | index($b)) | not
                )
              ))
            )
            | map(select(((.hooks // []) | length) > 0))
          )
        )
      | with_entries(select((.value | length) > 0))
    )

  # ---- RE-ADD from manifest (skip when uninstalling) ----
  | (if $uninstall then .
     else reduce $manifest[] as $e (.;
       .hooks[$e.event] = (
         (.hooks[$e.event] // []) + [
           (if ($e | has("matcher")) then {matcher: $e.matcher} else {} end)
           + { hooks: [
                 ( {type: "command", command: ($prefix + "/hooks/" + $e.script)}
                   + (if ($e | has("timeout")) then {timeout: $e.timeout} else {} end) )
               ] }
         ]
       )
     )
     end)

  # ---- env: add/remove MEMORY_PACK_HOME, never touch sibling env keys ----
  | (if $uninstall
     then (if (.env? | type) == "object" then del(.env.MEMORY_PACK_HOME) else . end)
     else .env = ((.env // {}) | .MEMORY_PACK_HOME = $prefix)
     end)

  # ---- statusLine: opt-in via --statusline; basename "statusline-command.sh"
  #      is the ownership key (mirrors hook script-basename ownership).
  #      Create-or-upgrade merges into the existing object so sibling keys
  #      (e.g. padding) survive; foreign statuslines are never touched. ----
  | (if $sl == "" then .
     else
       (((.statusLine.command // "") | tostring | split("/") | last) == "statusline-command.sh") as $mpsl
       | (if $uninstall
          then (if $mpsl then del(.statusLine) else . end)
          else (if (has("statusLine") | not) or $mpsl
                then .statusLine = ((.statusLine // {}) + {type: "command", command: ("bash " + $sl)})
                else . end)
          end)
     end)

  # ---- uninstall hygiene: drop env/hooks containers WE emptied (never
  #      when they still hold foreign keys; empty {} ≡ absent for CC) ----
  | (if $uninstall
     then (if ((.env?   | type) == "object") and ((.env   | length) == 0) then del(.env)   else . end)
        | (if ((.hooks? | type) == "object") and ((.hooks | length) == 0) then del(.hooks) else . end)
     else . end)
'
