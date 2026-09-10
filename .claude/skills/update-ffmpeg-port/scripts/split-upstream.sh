#!/usr/bin/env bash
# Step 1: extract upstream vcpkg's ports/ffmpeg history as a standalone branch.
#
#   split-upstream.sh <vcpkg-tag-or-commit> [--vcpkg PATH] [--base BRANCH]
#                     [--label LABEL] [--no-fetch] [--full-split]
#
# Extends the subtree history of upstream's ports/ffmpeg up to the requested ref
# (seconds), checks the result is a forward move from what this registry already
# merged, and records what the follow-up scripts need in
# .git/resolume-ffmpeg-update.env. --full-split rebuilds the same history with
# `git subtree split` instead - hours, only useful to cross-check the fast path.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REF=""; VCPKG_ARG=""; BASE_BRANCH="master"; LABEL=""; DO_FETCH=1; FULL_SPLIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --vcpkg)    VCPKG_ARG="${2:?}"; shift 2 ;;
    --base)     BASE_BRANCH="${2:?}"; shift 2 ;;
    --label)    LABEL="${2:?}"; shift 2 ;;
    --no-fetch)   DO_FETCH=0; shift ;;
    --full-split) FULL_SPLIT=1; shift ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    -*)         die "unknown option $1" ;;
    *)          [ -z "$REF" ] || die "unexpected argument $1"; REF="$1"; shift ;;
  esac
done
[ -n "$REF" ] || die "usage: split-upstream.sh <vcpkg-tag-or-commit> [options]"

VCPKG_DIR="$(resolve_vcpkg_dir "$VCPKG_ARG")"
vg() { git -C "$VCPKG_DIR" "$@"; }
info "vcpkg clone: $VCPKG_DIR"

case "$(vg remote get-url origin 2>/dev/null || true)" in
  *microsoft/vcpkg*) ;;
  *) warn "origin of $VCPKG_DIR is not microsoft/vcpkg - is this the official repo?" ;;
esac

if [ "$DO_FETCH" = 1 ]; then
  info "fetching origin (tags included)"
  vg fetch --tags --prune origin >&2 || warn "fetch failed - continuing with the local history"
fi

# Resolve the requested ref: plain rev, then tag, then remote branch.
SHA=""
for cand in "$REF" "refs/tags/$REF" "origin/$REF"; do
  if SHA="$(vg rev-parse --verify --quiet "${cand}^{commit}")"; then break; fi
  SHA=""
done
[ -n "$SHA" ] || die "'$REF' is not a tag, branch or commit in $VCPKG_DIR (try without --no-fetch)"

TARGET_TREE="$(vg rev-parse --verify "$SHA:$PORT_PREFIX")" \
  || die "commit $SHA has no $PORT_PREFIX directory"

UP_VERSION="$(vg show "$SHA:$PORT_PREFIX/vcpkg.json" | jq -er '.version')"
UP_PORT_VERSION="$(vg show "$SHA:$PORT_PREFIX/vcpkg.json" | jq -er '."port-version" // 0')"
NEW_PORT_VERSION=$((UP_PORT_VERSION + PORT_VERSION_OFFSET))

# Branch labels: date tags stay as-is (2026.09.05-ffmpeg-update), anything else
# is identified by its short sha.
if [ -z "$LABEL" ]; then
  if [[ "$REF" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]]; then LABEL="$REF"
  else LABEL="$(vg rev-parse --short=9 "$SHA")"; fi
fi
LABEL="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '-')"

BASE="$(base_commit "$BASE_BRANCH")"
PREV_UPSTREAM="$(greg rev-parse "$BASE^2")"
PREV_TREE="$(greg rev-parse "$BASE:$PORT_PREFIX")"

printf '\n'
info "requested   : $REF -> $SHA"
info "upstream    : ffmpeg $UP_VERSION port-version $UP_PORT_VERSION"
info "registry    : $BASE_BRANCH, last subtree merge ${BASE:0:9} (upstream tip ${PREV_UPSTREAM:0:9})"
printf '\n'

if [ "$TARGET_TREE" = "$PREV_TREE" ]; then
  ok "$PORT_PREFIX at $REF is byte-identical to what $BASE_BRANCH already merged - nothing to update"
  exit 3
fi

# Copy one upstream commit into the split history: same author, committer,
# dates and message, tree replaced by the subtree's tree. This is exactly what
# git-subtree's copy_commit does, so the resulting shas are identical to a full
# `git subtree split` - verified against this repo's own history.
replay_commit() { # replay_commit <upstream-commit> <subtree-tree> <parent>
  vg log -1 --no-show-signature \
      --pretty=format:'%an%n%ae%n%aD%n%cn%n%ce%n%cD%n%B' "$1" | (
    read -r GIT_AUTHOR_NAME; read -r GIT_AUTHOR_EMAIL; read -r GIT_AUTHOR_DATE
    read -r GIT_COMMITTER_NAME; read -r GIT_COMMITTER_EMAIL; read -r GIT_COMMITTER_DATE
    export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
           GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
    git -C "$VCPKG_DIR" commit-tree "$2" -p "$3"   # message from the rest of stdin
  )
}

# The upstream commit whose ports/ffmpeg is what this registry already merged.
# Everything after it is what the split history is missing.
find_boundary() {
  local c
  while read -r c; do
    if [ "$(vg rev-parse --verify --quiet "$c:$PORT_PREFIX" || true)" = "$PREV_TREE" ]; then
      printf '%s' "$c"; return 0
    fi
  done < <(vg rev-list "$SHA" -- "$PORT_PREFIX")
  return 1
}

SPLIT_BRANCH="resolume-split/$LABEL"
if [ "$(vg rev-parse --verify --quiet "$SPLIT_BRANCH^{tree}" || true)" = "$TARGET_TREE" ]; then
  ok "reusing cached split branch $SPLIT_BRANCH"
elif [ "$FULL_SPLIT" = 1 ]; then
  vg branch -D "$SPLIT_BRANCH" >/dev/null 2>&1 || true
  info "running git subtree split over all of vcpkg history - this takes hours"
  vg subtree split --prefix="$PORT_PREFIX" -b "$SPLIT_BRANCH" "$SHA" >&2 \
    || die "git subtree split failed"
else
  # The split history so far lives in the registry; the vcpkg clone needs it to
  # continue the chain (a fresh clone has none of it).
  if ! vg rev-parse --verify --quiet "$PREV_UPSTREAM^{commit}" >/dev/null; then
    info "fetching the existing split history from the registry"
    vg fetch -q --no-tags "$REGISTRY_ROOT" "refs/heads/$BASE_BRANCH" >&2 \
      || die "could not fetch $BASE_BRANCH from $REGISTRY_ROOT"
  fi
  vg rev-parse --verify --quiet "$PREV_UPSTREAM^{commit}" >/dev/null \
    || die "the previously merged split commit ${PREV_UPSTREAM:0:9} is not in $VCPKG_DIR"

  boundary="$(find_boundary || true)"
  if [ -z "$boundary" ]; then
    die "cannot find the upstream commit matching what $BASE_BRANCH already merged
       (tree $PREV_TREE). Either $REF is from a different vcpkg history, or the
       previous round's $PORT_PREFIX was not taken from upstream unchanged.
       This needs a human: compare $BASE_BRANCH:$PORT_PREFIX with upstream's."
  fi
  info "extending the split history from ${PREV_UPSTREAM:0:9} (upstream ${boundary:0:9})"

  tip="$PREV_UPSTREAM"; count=0
  while read -r c; do
    tip="$(replay_commit "$c" "$(vg rev-parse "$c:$PORT_PREFIX")" "$tip")" \
      || die "could not copy upstream commit $c"
    count=$((count + 1))
  done < <(vg rev-list --reverse --topo-order "$boundary..$SHA" -- "$PORT_PREFIX")
  [ "$count" -gt 0 ] || die "no upstream commits to copy, yet the trees differ - please report"
  vg branch -f "$SPLIT_BRANCH" "$tip" >/dev/null
  ok "copied $count upstream commit(s) into $SPLIT_BRANCH"
fi

SPLIT_TIP="$(vg rev-parse "$SPLIT_BRANCH")"
[ "$(vg rev-parse "$SPLIT_TIP^{tree}")" = "$TARGET_TREE" ] \
  || die "split tip tree does not match $REF:$PORT_PREFIX - refusing to continue"

if [ "$SPLIT_TIP" = "$PREV_UPSTREAM" ]; then
  ok "no upstream ffmpeg commits since ${PREV_UPSTREAM:0:9} - nothing to update"
  exit 3
fi
if ! vg rev-parse --verify --quiet "$PREV_UPSTREAM^{commit}" >/dev/null \
   || ! vg merge-base --is-ancestor "$PREV_UPSTREAM" "$SPLIT_TIP"; then
  die "$REF does not contain the upstream ffmpeg state already merged into $BASE_BRANCH
       (${PREV_UPSTREAM:0:9} is not an ancestor of the split at ${SPLIT_TIP:0:9}).
       The requested ref is older than, or has diverged from, what this registry
       is already on. Pick a newer vcpkg tag/commit."
fi

state_clear
state_save \
  REF="$REF" SHA="$SHA" LABEL="$LABEL" \
  VCPKG_DIR="$VCPKG_DIR" SPLIT_BRANCH="$SPLIT_BRANCH" SPLIT_TIP="$SPLIT_TIP" \
  BASE_BRANCH="$BASE_BRANCH" BASE="$BASE" PREV_UPSTREAM="$PREV_UPSTREAM" \
  PORT_BRANCH="$LABEL-ffmpeg-port" UPDATE_BRANCH="$LABEL-ffmpeg-update" \
  UP_VERSION="$UP_VERSION" UP_PORT_VERSION="$UP_PORT_VERSION" \
  NEW_PORT_VERSION="$NEW_PORT_VERSION"

printf '\n'
ok "split branch $SPLIT_BRANCH at ${SPLIT_TIP:0:9}"
printf '\n%s\n' "new upstream ffmpeg commits to pull in:"
vg log --oneline --no-decorate "$PREV_UPSTREAM..$SPLIT_TIP"
printf '\n%s\n' "this update will produce:"
printf '  branches      %s / %s\n' "$LABEL-ffmpeg-port" "$LABEL-ffmpeg-update"
printf '  ffmpeg        %s (was %s)\n' "$UP_VERSION" "$(greg show "$BASE_BRANCH:$PORT_PREFIX/vcpkg.json" | jq -er '.version')"
printf '  port-version  %s (upstream %s + %s)\n' "$NEW_PORT_VERSION" "$UP_PORT_VERSION" "$PORT_VERSION_OFFSET"
printf '\nnext: scripts/start-update.sh\n'
