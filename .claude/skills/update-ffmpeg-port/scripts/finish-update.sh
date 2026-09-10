#!/usr/bin/env bash
# Step 3: set the new version/port-version, register the git-tree in the version
# database, and fold both into the resolume commit.
#
#   finish-update.sh [--port-version N] [--keep-bookkeeping-commits]
#
# Run it on the update branch after the rebase has completed cleanly. Commits
# that upstream has made redundant - the ones left carrying nothing but a
# port-version bump - are dropped unless --keep-bookkeeping-commits is given.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PV_OVERRIDE=""; PRUNE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --port-version)             PV_OVERRIDE="${2:?}"; shift 2 ;;
    --keep-bookkeeping-commits) PRUNE=0; shift ;;
    -h|--help)                  sed -n '2,12p' "$0"; exit 0 ;;
    *)                          die "unknown argument $1" ;;
  esac
done

state_load
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rebase_in_progress && die "the rebase is still in progress - resolve the conflicts and 'git rebase --continue' first"
current="$(greg rev-parse --abbrev-ref HEAD)"
[ "$current" = "$UPDATE_BRANCH" ] || die "on branch '$current' but this update belongs on '$UPDATE_BRANCH'"
require_clean_worktree
greg merge-base --is-ancestor "$PORT_TIP" HEAD \
  || die "HEAD is not built on $PORT_BRANCH (${PORT_TIP:0:9}) - did the rebase run?"
greg grep -qIn -e '^<<<<<<< ' -- "$PORT_PREFIX" >/dev/null 2>&1 \
  && die "conflict markers left under $PORT_PREFIX - resolve them before finishing"

PV="${PV_OVERRIDE:-$NEW_PORT_VERSION}"
info "target: ffmpeg $UP_VERSION, port-version $PV (upstream $UP_PORT_VERSION + $PORT_VERSION_OFFSET)"

# The version files are amended into the tip commit, which is normally the
# resolume customizations commit. If master carries later commits that have
# nothing to do with the port (this skill, README edits), the tip is one of those
# instead: harmless for vcpkg, which resolves versions by git-tree, but untidy.
if [ -z "$(greg diff --name-only HEAD~1 HEAD -- "$PORT_PREFIX")" ]; then
  port_commit="$(greg rev-list -1 "$PORT_TIP..HEAD" -- "$PORT_PREFIX" || true)"
  warn "the tip commit '$(greg log -1 --format=%s)' does not touch $PORT_PREFIX;
       the version files land there anyway. For the shape the repo usually has,
       move ${port_commit:0:9} ('$(greg log -1 --format=%s "$port_commit" 2>/dev/null)') last
       with 'git rebase -i $PORT_BRANCH', or keep it as the tip of $BASE_BRANCH."
fi

# 0. Commits whose whole remaining content is version bookkeeping exist only
#    because upstream absorbed what they used to carry. Drop them.
if [ "$PRUNE" = 1 ]; then
  old_tip="$(greg rev-parse HEAD)"
  new_tip="$("$HERE/prune_bookkeeping.py" --root "$REGISTRY_ROOT" --from "$PORT_TIP" \
             --version "$UP_VERSION" --port-version "$PV")" \
    || die "pruning failed - $UPDATE_BRANCH is untouched"
  if [ "$new_tip" != "$old_tip" ]; then
    greg reset -q --hard "$new_tip"
    ok "pruned to $(greg rev-list --count "$PORT_TIP..HEAD") commit(s); previous tip ${old_tip:0:9} is in the reflog"
  fi
fi

# 1. version + port-version in the port manifest, amended into the resolume commit
"$HERE/update_versions.py" port --root "$REGISTRY_ROOT" --version "$UP_VERSION" --port-version "$PV"
if [ -n "$(greg status --porcelain -- "$PORT_PREFIX/vcpkg.json")" ]; then
  greg add -- "$PORT_PREFIX/vcpkg.json"
  greg commit -q --amend --no-edit
  ok "amended $PORT_PREFIX/vcpkg.json into $(greg log -1 --format='%h %s')"
fi

# 2. the git-tree can only be read once ports/ffmpeg is committed and final
GIT_TREE="$(greg rev-parse "HEAD:$PORT_PREFIX")"
info "git-tree of $PORT_PREFIX: $GIT_TREE"

# 3. version database + baseline, amended in as well. Both live outside
#    ports/ffmpeg, so amending them cannot change the git-tree recorded above.
"$HERE/update_versions.py" versions --root "$REGISTRY_ROOT" \
  --version "$UP_VERSION" --port-version "$PV" --git-tree "$GIT_TREE"
if [ -n "$(greg status --porcelain -- versions)" ]; then
  greg add -- versions
  greg commit -q --amend --no-edit
  ok "amended versions/ into $(greg log -1 --format='%h %s')"
fi

[ "$(greg rev-parse "HEAD:$PORT_PREFIX")" = "$GIT_TREE" ] \
  || die "internal error: $PORT_PREFIX tree changed while amending the version files"

state_save GIT_TREE="$GIT_TREE" FINAL_PORT_VERSION="$PV"
printf '\n'
"$HERE/verify.sh"

printf '\n%s\n' "$UPDATE_BRANCH is ready:"
greg log --oneline --no-decorate -3 | sed 's/^/    /'
cat <<NEXT

next:
  scripts/check-patches.sh          verify the resolume patches still apply to ffmpeg $UP_VERSION
  git push forpr $UPDATE_BRANCH     push to the fork, then open the PR
NEXT
