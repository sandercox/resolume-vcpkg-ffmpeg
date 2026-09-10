#!/usr/bin/env bash
# Optional but recommended: check that every patch the portfile applies still
# applies to the new ffmpeg source. Upstream vcpkg keeps its own patches in
# shape, but the resolume 1xxx patches are ours - a new ffmpeg release usually
# moves their context and they need refreshing.
#
#   check-patches.sh [--version X.Y.Z] [--offline]
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERSION=""; OFFLINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?}"; shift 2 ;;
    --offline) OFFLINE=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *)         die "unknown argument $1" ;;
  esac
done

PORT_DIR="$REGISTRY_ROOT/$PORT_PREFIX"
VERSION="${VERSION:-$(jq -er '.version' "$PORT_DIR/vcpkg.json")}"

# The vcpkg_from_github() call, comments stripped, as a flat token stream - the
# portfile has been formatted both one-arg-per-line and key-and-value-per-line.
tokens="$(awk '/^vcpkg_from_github\(/{f=1} f&&/^\)/{exit} f' "$PORT_DIR/portfile.cmake" \
          | sed 's/#.*//' | tr -s ' \t\n' '\n')"
token_after() { printf '%s\n' "$tokens" | awk -v k="$1" '$0==k{getline; print; exit}'; }

REPO="$(token_after REPO)"
REF="$(token_after REF | tr -d '"')"
SHA512="$(token_after SHA512)"
TAG="${REF//\$\{VERSION\}/$VERSION}"
[ -n "$REPO" ] && [ -n "$TAG" ] || die "could not read REPO/REF from the portfile"

TARBALL="$CACHE_DIR/$(printf '%s' "$REPO" | tr / -)-$TAG.tar.gz"
SRC_DIR="$CACHE_DIR/src/$(printf '%s' "$REPO" | tr / -)-$TAG"
mkdir -p "$CACHE_DIR/src"

if [ ! -s "$TARBALL" ]; then
  [ "$OFFLINE" = 0 ] || die "no cached tarball at $TARBALL and --offline was given"
  info "downloading https://github.com/$REPO/archive/$TAG.tar.gz"
  curl -fsSL --retry 3 -o "$TARBALL.part" "https://github.com/$REPO/archive/$TAG.tar.gz" \
    || die "download failed - is $TAG a real $REPO tag?"
  mv "$TARBALL.part" "$TARBALL"
fi

if [ -n "$SHA512" ]; then
  got="$(sha512sum "$TARBALL" 2>/dev/null | cut -d' ' -f1 || shasum -a 512 "$TARBALL" | cut -d' ' -f1)"
  if [ "$got" = "$SHA512" ]; then ok "tarball SHA512 matches the portfile"
  else warn "tarball SHA512 does not match the portfile
       portfile: $SHA512
       download: $got
       if the version was just bumped, put the downloaded hash in the portfile"; fi
fi

info "extracting to $SRC_DIR"
rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
tar -xzf "$TARBALL" -C "$SRC_DIR" --strip-components=1

# A throwaway git repo makes it easy to regenerate a patch with `git diff`.
git -C "$SRC_DIR" init -q
git -C "$SRC_DIR" -c core.safecrlf=false add -A >/dev/null
git -C "$SRC_DIR" -c user.name=vcpkg -c user.email=vcpkg@local \
    commit -qm "ffmpeg $TAG pristine" >/dev/null

printf '\napplying the portfile patch series to ffmpeg %s:\n\n' "$VERSION"
failed=()
while read -r p; do
  [ -n "$p" ] || continue
  if git -C "$SRC_DIR" apply -p1 --ignore-whitespace --whitespace=nowarn "$PORT_DIR/$p" 2>/dev/null; then
    printf '  %sok  %s %s\n' "$C_GRN" "$C_OFF" "$p"
  elif (cd "$SRC_DIR" && patch -p1 -F3 --dry-run --silent <"$PORT_DIR/$p" >/dev/null 2>&1); then
    printf '  %sfuzz%s %s (applies only with fuzz - refresh it)\n' "$C_YEL" "$C_OFF" "$p"
    (cd "$SRC_DIR" && patch -p1 -F3 --silent <"$PORT_DIR/$p" >/dev/null 2>&1) || true
    failed+=("$p")
  else
    printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$p"
    failed+=("$p")
  fi
done < <(portfile_patches)

printf '\n'
if [ "${#failed[@]}" = 0 ]; then
  ok "the whole patch series applies cleanly to ffmpeg $VERSION"
  exit 0
fi

warn "${#failed[@]} patch(es) need attention: ${failed[*]}"
cat <<HINT

To refresh one of them, in $SRC_DIR:
  git checkout . && git clean -qfd                     # back to pristine
  patch -p1 -F3 <$PORT_DIR/<earlier patches...>        # replay the series up to it
  patch -p1 -F3 <$PORT_DIR/<the failing patch>         # or hand-edit the source
  git diff -- <the touched files> >$PORT_DIR/<the failing patch>

Then re-run this script; it must come out clean before the port can build.
HINT
exit 1
