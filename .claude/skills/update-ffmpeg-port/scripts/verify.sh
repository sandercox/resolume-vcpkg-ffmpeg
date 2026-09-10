#!/usr/bin/env bash
# Check the invariants of a finished (or in-progress) update. Safe to run at any
# point; needs no state file when --against is given.
#
#   verify.sh [--against <upstream-ref>] [--base BRANCH]
#
# --against is the pure-upstream port branch (default: the one recorded by
# split-upstream.sh) that HEAD is compared with.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGAINST=""; BASE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --against) AGAINST="${2:?}"; shift 2 ;;
    --base)    BASE_ARG="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *)         die "unknown argument $1" ;;
  esac
done

if [ -f "$STATE_FILE" ]; then . "$STATE_FILE"; fi
AGAINST="${AGAINST:-${PORT_TIP:-${PORT_BRANCH:-}}}"
BASE_BRANCH="${BASE_ARG:-${BASE_BRANCH:-master}}"

fails=0
fail()  { printf '%sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$*"; fails=$((fails + 1)); }
pass()  { printf '%spass%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
note()  { printf '%swarn%s  %s\n' "$C_YEL" "$C_OFF" "$*"; }

cd "$REGISTRY_ROOT"
printf 'verifying %s\n\n' "$(greg rev-parse --abbrev-ref HEAD)"

# 1. no half-finished merge left behind
if rebase_in_progress; then fail "a rebase is still in progress"; else pass "no rebase in progress"; fi
if greg grep -qIn -e '^<<<<<<< ' -e '^>>>>>>> ' -- "$PORT_PREFIX" versions 2>/dev/null; then
  fail "conflict markers left in the tree:"; greg grep -In -e '^<<<<<<< ' -- "$PORT_PREFIX" versions | sed 's/^/        /'
else
  pass "no conflict markers under $PORT_PREFIX/ or versions/"
fi

# 2. the three version records agree with each other
VERSION="$(jq -er '.version' "$PORT_PREFIX/vcpkg.json")" || fail "cannot read version from $PORT_PREFIX/vcpkg.json"
PV="$(jq -er '."port-version" // 0' "$PORT_PREFIX/vcpkg.json")"
TOP_VERSION="$(jq -er '.versions[0].version' "$VERSIONS_FILE")"
TOP_PV="$(jq -er '.versions[0]."port-version" // 0' "$VERSIONS_FILE")"
TOP_TREE="$(jq -er '.versions[0]."git-tree"' "$VERSIONS_FILE")"
BL_VERSION="$(jq -er '.default.ffmpeg.baseline' "$BASELINE_FILE")"
BL_PV="$(jq -er '.default.ffmpeg."port-version" // 0' "$BASELINE_FILE")"

if [ "$VERSION/$PV" = "$TOP_VERSION/$TOP_PV" ]; then
  pass "$VERSIONS_FILE entry matches the manifest ($VERSION port-version $PV)"
else
  fail "$VERSIONS_FILE entry is $TOP_VERSION#$TOP_PV but the manifest says $VERSION#$PV"
fi

# The registry publishes one version - the versions it shipped itself are not
# kept, since consumers follow a branch/tag and always take the newest.
ENTRIES="$(jq -er '.versions | length' "$VERSIONS_FILE")"
if [ "$ENTRIES" = 1 ]; then
  pass "$VERSIONS_FILE holds exactly one version"
else
  fail "$VERSIONS_FILE holds $ENTRIES versions - it should only publish the current one"
fi
if [ "$VERSION/$PV" = "$BL_VERSION/$BL_PV" ]; then
  pass "$BASELINE_FILE matches the manifest"
else
  fail "$BASELINE_FILE is $BL_VERSION#$BL_PV but the manifest says $VERSION#$PV"
fi

# 3. the recorded git-tree is the tree actually committed
HEAD_TREE="$(greg rev-parse "HEAD:$PORT_PREFIX")"
if [ "$TOP_TREE" = "$HEAD_TREE" ]; then
  pass "git-tree $HEAD_TREE matches HEAD:$PORT_PREFIX"
else
  fail "git-tree in $VERSIONS_FILE is $TOP_TREE but HEAD:$PORT_PREFIX is $HEAD_TREE"
fi
if [ -n "$(greg status --porcelain -- "$PORT_PREFIX")" ]; then
  fail "$PORT_PREFIX has uncommitted changes - the git-tree above is not what is committed"
else
  pass "$PORT_PREFIX is fully committed"
fi

# 4. resolume port-version convention
if [ -n "${UP_PORT_VERSION:-}" ]; then
  want=$((UP_PORT_VERSION + PORT_VERSION_OFFSET))
  if [ "$PV" = "$want" ]; then pass "port-version $PV = upstream $UP_PORT_VERSION + $PORT_VERSION_OFFSET"
  else fail "port-version $PV should be $want (upstream $UP_PORT_VERSION + $PORT_VERSION_OFFSET)"; fi
fi

# 5. patch bookkeeping
missing=0
while read -r p; do
  [ -n "$p" ] || continue
  [ -f "$PORT_PREFIX/$p" ] || { fail "portfile lists $p but the file is missing"; missing=1; }
done < <(portfile_patches)
[ "$missing" = 0 ] && pass "every patch listed in the portfile exists"

unlisted=""
listed="$(portfile_patches)"
for f in "$PORT_PREFIX"/*.patch; do
  b="$(basename "$f")"
  printf '%s\n' "$listed" | grep -qxF "$b" || unlisted="$unlisted $b"
done
if [ -n "$unlisted" ]; then note "patch files present but not applied by the portfile:$unlisted"
else pass "no orphaned patch files"; fi

# 6. the resolume customizations survived the rebase (see reference.md)
for marker in '# Resolume patches' '--install_name_dir=@rpath' 'VCPKG_FIXUP_MACHO_RPATH OFF'; do
  if grep -qF -- "$marker" "$PORT_PREFIX/portfile.cmake"; then pass "portfile still has: $marker"
  else fail "portfile lost the resolume change: $marker"; fi
done
for p in "$PORT_PREFIX"/1[0-9][0-9][0-9]-*.patch; do
  [ -e "$p" ] || { fail "no resolume (1xxx) patches found at all"; break; }
  b="$(basename "$p")"
  printf '%s\n' "$listed" | grep -qxF "$b" || fail "resolume patch $b is not listed in the portfile"
done

# 7. everything else under ports/ffmpeg must be upstream, byte for byte
if [ -n "$AGAINST" ] && greg rev-parse --verify --quiet "$AGAINST" >/dev/null; then
  changed="$(greg diff --name-only "$AGAINST" HEAD -- "$PORT_PREFIX")"
  unexpected="$(printf '%s\n' "$changed" | grep -v -e "^$PORT_PREFIX/portfile.cmake$" -e "^$PORT_PREFIX/vcpkg.json$" -e "^$PORT_PREFIX/1[0-9][0-9][0-9]-.*\.patch$" || true)"
  if [ -z "$unexpected" ]; then
    pass "only portfile.cmake, vcpkg.json and 1xxx patches differ from upstream ($AGAINST)"
  else
    note "these files differ from upstream but are not part of the known resolume delta:"
    printf '%s\n' "$unexpected" | sed 's/^/        /'
    note "review them - upstream content should not be modified by this repo"
  fi

  # reformatting noise: a diff that shrinks a lot under -w is whitespace churn
  full="$(greg diff --numstat "$AGAINST" HEAD -- "$PORT_PREFIX" | awk '{a+=$1+$2} END {print a+0}')"
  ws="$(greg diff -w --ignore-blank-lines --numstat "$AGAINST" HEAD -- "$PORT_PREFIX" | awk '{a+=$1+$2} END {print a+0}')"
  if [ "$full" -gt 0 ] && [ "$((full - ws))" -gt 50 ]; then
    note "delta is $full changed lines, but only $ws ignoring whitespace - the port looks reformatted"
    note "reformatting makes every future update conflict; resolve conflicts by keeping upstream formatting"
  else
    pass "delta has no significant whitespace-only churn ($full lines, $ws ignoring whitespace)"
  fi

  printf '\nresolume delta of this round:\n'
  greg diff --stat "$AGAINST" HEAD -- "$PORT_PREFIX" | sed 's/^/    /'
  printf '\nresolume delta of the previous round (%s):\n' "$BASE_BRANCH"
  prev_base="$(base_commit "$BASE_BRANCH")"
  greg diff --stat "$prev_base" "$BASE_BRANCH" -- "$PORT_PREFIX" | sed 's/^/    /'
else
  note "no upstream port branch to compare with - pass --against <ref> for the upstream-fidelity checks"
fi

printf '\n'
if [ "$fails" = 0 ]; then ok "all checks passed"; else printf '%s%s check(s) failed%s\n' "$C_RED" "$fails" "$C_OFF"; exit 1; fi
