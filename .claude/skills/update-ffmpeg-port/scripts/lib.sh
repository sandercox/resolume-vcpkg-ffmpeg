#!/usr/bin/env bash
# Shared helpers for the update-ffmpeg-port skill. Sourced by the other
# scripts in this directory, not meant to be executed on its own.

PORT_PREFIX="ports/ffmpeg"
VERSIONS_FILE="versions/f-/ffmpeg.json"
BASELINE_FILE="versions/baseline.json"

# Resolume port-version = upstream port-version + this offset (7.1.1/1 -> 101,
# 8.1.1/2 -> 102, ...). Override with RESOLUME_PORT_VERSION_OFFSET if the
# convention ever changes.
PORT_VERSION_OFFSET="${RESOLUME_PORT_VERSION_OFFSET:-100}"

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/resolume-vcpkg-ffmpeg"
UPSTREAM_URL="https://github.com/microsoft/vcpkg.git"

if [ -t 1 ]; then C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_CYA=$'\033[36m'; C_GRN=$'\033[32m'; C_OFF=$'\033[0m'
else C_RED=; C_YEL=; C_CYA=; C_GRN=; C_OFF=; fi

die()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
warn() { printf '%swarn:%s  %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
info() { printf '%s==>%s %s\n' "$C_CYA" "$C_OFF" "$*" >&2; }
ok()   { printf '%s ok%s  %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }

# --- registry repo -----------------------------------------------------------

REGISTRY_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repository"
[ -f "$REGISTRY_ROOT/$PORT_PREFIX/portfile.cmake" ] && [ -f "$REGISTRY_ROOT/$VERSIONS_FILE" ] \
  || die "$REGISTRY_ROOT does not look like the resolume vcpkg-ffmpeg registry"

STATE_FILE="$REGISTRY_ROOT/.git/resolume-ffmpeg-update.env"

state_save() { # state_save KEY=VALUE ...
  local kv
  for kv in "$@"; do
    local key="${kv%%=*}" val="${kv#*=}"
    [ -f "$STATE_FILE" ] && sed -i "/^${key}=/d" "$STATE_FILE"
    printf '%s=%q\n' "$key" "$val" >>"$STATE_FILE"
  done
}

state_load() {
  [ -f "$STATE_FILE" ] || die "no update in progress; run split-upstream.sh <vcpkg-ref> first"
  # shellcheck disable=SC1090
  . "$STATE_FILE"
}

state_clear() { rm -f "$STATE_FILE"; }

greg() { git -C "$REGISTRY_ROOT" "$@"; }   # git in the registry repo

require_clean_worktree() {
  greg update-index -q --refresh || true
  greg diff-files --quiet -- || die "registry working tree has unstaged changes; commit or stash them first"
  greg diff-index --quiet --cached HEAD -- || die "registry index has staged changes; commit or reset them first"
  [ -z "$(greg ls-files --others --exclude-standard -- "$PORT_PREFIX" versions)" ] \
    || die "untracked files under $PORT_PREFIX/ or versions/; clean them up first"
}

rebase_in_progress() {
  local d; d="$(greg rev-parse --git-path rebase-merge)"
  local a; a="$(greg rev-parse --git-path rebase-apply)"
  [ -d "$REGISTRY_ROOT/$d" ] || [ -d "$d" ] || [ -d "$REGISTRY_ROOT/$a" ] || [ -d "$a" ]
}

# Last subtree merge on the given branch's first-parent chain. That merge commit
# is the pure-upstream state the resolume customizations sit on top of; the
# README calls it `master^1`.
base_commit() { # base_commit <branch>
  local b="$1" base
  base="$(greg rev-list --merges --first-parent -1 "$b")" \
    || die "cannot walk $b"
  [ -n "$base" ] || die "no subtree merge commit found on $b"
  [ "$(greg rev-list --count --no-walk "$base^2" 2>/dev/null)" = "1" ] \
    || die "$base is not a two-parent subtree merge"
  printf '%s' "$base"
}

# --- vcpkg clone -------------------------------------------------------------

is_vcpkg_repo() {
  local d="${1:-}"
  [ -n "$d" ] && [ -e "$d/.git" ] && [ -d "$d/$PORT_PREFIX" ]
}

resolve_vcpkg_dir() { # resolve_vcpkg_dir [explicit-path]
  local explicit="${1:-}" c
  if [ -n "$explicit" ]; then
    is_vcpkg_repo "$explicit" || die "--vcpkg '$explicit' is not a vcpkg clone"
    (cd "$explicit" && pwd); return
  fi
  for c in "${VCPKG_ROOT:-}" "$HOME/develop/vcpkg" "$CACHE_DIR/vcpkg"; do
    if is_vcpkg_repo "$c"; then (cd "$c" && pwd); return; fi
  done
  info "no vcpkg clone found - cloning $UPSTREAM_URL into $CACHE_DIR/vcpkg (a few minutes)"
  mkdir -p "$CACHE_DIR"
  git clone "$UPSTREAM_URL" "$CACHE_DIR/vcpkg" >&2 || die "clone of $UPSTREAM_URL failed"
  printf '%s' "$CACHE_DIR/vcpkg"
}

# --- misc --------------------------------------------------------------------

# Patch file names listed in the portfile's vcpkg_from_github() PATCHES block,
# in application order.
portfile_patches() { # portfile_patches [portfile]
  local pf="${1:-$REGISTRY_ROOT/$PORT_PREFIX/portfile.cmake}"
  awk '
    /^vcpkg_from_github\(/ { inblock = 1 }
    inblock && /^\)/       { exit }
    inblock                { sub(/#.*/, ""); if (match($0, /[A-Za-z0-9._+-]+\.patch/)) print substr($0, RSTART, RLENGTH) }
  ' "$pf"
}

json_get() { # json_get <file-or-> <jq-filter>
  jq -er "$2" "$1"
}
