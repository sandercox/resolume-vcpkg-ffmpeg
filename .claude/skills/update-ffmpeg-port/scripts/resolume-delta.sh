#!/usr/bin/env bash
# Print the resolume delta of the *previous* round: everything under ports/ that
# the resolume commit(s) add on top of the pure-upstream subtree merge. Use it
# to re-apply the delta by hand when a rebase conflicts, and to sanity-check the
# new round's delta against it.
#
#   resolume-delta.sh [--base BRANCH] [--stat] [--with-vcpkg-json] [-o FILE]
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_ARG=""; OUT=""; STAT=0; WITH_MANIFEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base)             BASE_ARG="${2:?}"; shift 2 ;;
    --stat)             STAT=1; shift ;;
    --with-vcpkg-json)  WITH_MANIFEST=1; shift ;;
    -o)                 OUT="${2:?}"; shift 2 ;;
    -h|--help)          sed -n '2,9p' "$0"; exit 0 ;;
    *)                  die "unknown argument $1" ;;
  esac
done

# Default to the base branch of the update in progress, if there is one.
BASE_BRANCH="$BASE_ARG"
if [ -z "$BASE_BRANCH" ] && [ -f "$STATE_FILE" ]; then
  BASE_BRANCH="$(sed -n "s/^BASE_BRANCH=//p" "$STATE_FILE" | tr -d "'\"")"
fi
BASE_BRANCH="${BASE_BRANCH:-master}"
BASE="$(base_commit "$BASE_BRANCH")"

# ports/ffmpeg/vcpkg.json is excluded by default: its only resolume change is the
# port-version bump, which finish-update.sh recomputes for the new version.
pathspec=("$PORT_PREFIX")
[ "$WITH_MANIFEST" = 1 ] || pathspec+=(":!$PORT_PREFIX/vcpkg.json")

info "resolume delta of $BASE_BRANCH on top of ${BASE:0:9}"
if [ "$STAT" = 1 ]; then
  greg diff --stat "$BASE".."$BASE_BRANCH" -- "${pathspec[@]}"
elif [ -n "$OUT" ]; then
  greg diff --binary "$BASE".."$BASE_BRANCH" -- "${pathspec[@]}" >"$OUT"
  ok "written to $OUT"
  greg diff --stat "$BASE".."$BASE_BRANCH" -- "${pathspec[@]}"
else
  greg diff "$BASE".."$BASE_BRANCH" -- "${pathspec[@]}"
fi
