#!/usr/bin/env bash
# Step 2: pull the upstream subtree into a port branch and rebase the resolume
# customizations on top of it.
#
#   start-update.sh [--force]
#
# Exit codes: 0 = rebase clean, 2 = rebase stopped on conflicts (resolve them,
# then `git rebase --continue`), 1 = hard error.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *)         die "unknown argument $1" ;;
  esac
done

state_load
rebase_in_progress && die "a rebase is already in progress - finish or 'git rebase --abort' it first"
require_clean_worktree

for b in "$PORT_BRANCH" "$UPDATE_BRANCH"; do
  if tip="$(greg rev-parse --verify --quiet "$b")"; then
    [ "$FORCE" = 1 ] || die "branch $b already exists at ${tip:0:9}; pass --force to recreate it (the old tip stays in the reflog)"
    warn "recreating $b (was ${tip:0:9})"
  fi
done

CUSTOMIZATIONS="$(greg rev-list --count --first-parent "$BASE..$BASE_BRANCH")"
[ "$CUSTOMIZATIONS" -gt 0 ] || die "no resolume commits found between ${BASE:0:9} and $BASE_BRANCH"
info "replaying $CUSTOMIZATIONS resolume commit(s) from $BASE_BRANCH:"
greg log --oneline --no-decorate --first-parent "$BASE..$BASE_BRANCH" >&2

# --- upstream-only branch ----------------------------------------------------

info "creating $PORT_BRANCH at the previous subtree merge ${BASE:0:9}"
greg checkout -q -B "$PORT_BRANCH" "$BASE" >&2

info "git subtree pull $SPLIT_BRANCH -> $PORT_PREFIX"
greg subtree pull --prefix="$PORT_PREFIX" "$VCPKG_DIR" "$SPLIT_BRANCH" >&2 \
  || die "subtree pull failed - $PORT_BRANCH is left as-is for inspection"

PULLED_TREE="$(greg rev-parse "HEAD:$PORT_PREFIX")"
TARGET_TREE="$(git -C "$VCPKG_DIR" rev-parse "$SHA:$PORT_PREFIX")"
[ "$PULLED_TREE" = "$TARGET_TREE" ] \
  || die "$PORT_PREFIX after the pull does not match $REF - expected $TARGET_TREE, got $PULLED_TREE"
ok "$PORT_BRANCH now carries upstream $PORT_PREFIX exactly as of $REF"
state_save PORT_TIP="$(greg rev-parse HEAD)"

# --- resolume customizations on top ------------------------------------------

info "creating $UPDATE_BRANCH from $BASE_BRANCH and rebasing onto $PORT_BRANCH"
greg checkout -q -B "$UPDATE_BRANCH" "$BASE_BRANCH" >&2

if GIT_SEQUENCE_EDITOR=true GIT_EDITOR=true \
   greg rebase -i --autosquash "$PORT_BRANCH" >&2; then
  ok "rebase clean - no conflicts"
  printf '\nnext: scripts/finish-update.sh\n'
  exit 0
fi

# git ls-files -u is authoritative for unmerged paths; `git diff --diff-filter=U`
# can under-report and leave you resolving only some of the conflicted files.
conflicted="$(greg ls-files -u | cut -f2 | sort -u || true)"
printf '\n'
warn "rebase stopped on conflicts in:"
printf '%s\n' "$conflicted" | sed 's/^/    /' >&2
cat >&2 <<'HINT'

Resolve them, then `git rebase --continue`, then run scripts/finish-update.sh.
Recipe that keeps the resolume delta small (see reference.md):
  ours   = upstream (the port branch being rebased onto)
  theirs = the resolume customizations commit

  F=ports/ffmpeg/portfile.cmake
  scripts/resolume-delta.sh -o /tmp/resolume-delta.patch   # previous round's delta
  git checkout --ours "$F" && git add "$F"                 # take upstream, stage it
  git apply -3 --include="$F" /tmp/resolume-delta.patch    # re-apply the resolume hunks
  # small markers may be left where upstream moved the code - fix by hand, then
  git add "$F"

  git checkout --ours ports/ffmpeg/vcpkg.json              # version fields: always
  git add ports/ffmpeg/vcpkg.json                          # upstream, finish-update sets them

Do not resolve by reformatting the file: outside the resolume hunks, ports/ffmpeg
must stay byte-identical to upstream.

A commit can conflict in several files at once, and each `git rebase --continue`
can stop again on the next commit. After every resolution check
`git ls-files -u` (empty = nothing unmerged left) and read what --continue says
instead of assuming it went through.
HINT
exit 2
