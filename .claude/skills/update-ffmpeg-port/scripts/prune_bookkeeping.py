#!/usr/bin/env python3
"""Drop replayed commits that only carry version bookkeeping.

Upstream regularly absorbs a resolume change (it gets upstreamed, or upstream
solves the same problem its own way). What is left of such a commit after the
rebase is nothing but a port-version bump, and this registry does not keep the
versions it shipped itself - so the commit has no reason to exist.

Every commit in <from>..HEAD is rebuilt with its bookkeeping neutralised:
`versions/` as it is in <from>, and the `version`/`port-version` keys of the
port manifest set to the values this round will publish. A commit whose rebuilt
tree then equals its parent's contributed nothing but bookkeeping and is
dropped. Everything else - trees, authors, committers, dates, messages - is
preserved, so surviving commits keep their identity.

Prints the new tip (unchanged if nothing was dropped).
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

MANIFEST = "ports/ffmpeg/vcpkg.json"
VERSIONS_DIR = "versions"


def git(*args, root, binary=False, stdin=None, env=None, may_fail=False):
    full = dict(os.environ)
    full.update(env or {})
    done = subprocess.run(
        ["git", "-C", str(root), *args], input=stdin, capture_output=True, env=full,
    )
    if done.returncode != 0:
        if may_fail:
            return None
        sys.exit(f"git {' '.join(args[:3])} failed: {done.stderr.decode().strip()}")
    return done.stdout if binary else done.stdout.decode().strip()


def normalized_manifest(root, commit, version, port_version):
    """The commit's manifest with this round's version fields, as a new blob."""
    raw = git("cat-file", "blob", f"{commit}:{MANIFEST}", root=root, binary=True).decode()
    raw, n = re.subn(r'(?m)^(\s*"version"\s*:\s*)"[^"]*"',
                     lambda m: m.group(1) + f'"{version}"', raw, count=1)
    if n != 1:
        sys.exit(f"{MANIFEST} in {commit[:9]}: expected one \"version\" key")
    raw, n = re.subn(r'(?m)^(\s*"port-version"\s*:\s*)\d+',
                     lambda m: m.group(1) + str(port_version), raw, count=1)
    if n == 0:
        raw, n = re.subn(r'(?m)^(\s*)("version"\s*:\s*"[^"]*",)$',
                         lambda m: f'{m.group(1)}{m.group(2)}\n{m.group(1)}"port-version": {port_version},',
                         raw, count=1)
        if n != 1:
            sys.exit(f"{MANIFEST} in {commit[:9]}: could not place a port-version key")
    # Upstream's manifest ends with a newline; older resolume rounds stripped it,
    # which otherwise makes a bookkeeping-only commit look like a real change.
    raw = raw.rstrip("\n") + "\n"
    return git("hash-object", "-w", "--stdin", root=root, stdin=raw.encode())


def rebuilt_tree(root, commit, base_versions_tree, version, port_version):
    with tempfile.TemporaryDirectory() as tmp:
        env = {"GIT_INDEX_FILE": str(Path(tmp) / "index")}
        git("read-tree", f"{commit}^{{tree}}", root=root, env=env)
        git("rm", "-r", "-q", "-f", "--cached", "--ignore-unmatch", VERSIONS_DIR, root=root, env=env)
        if base_versions_tree:
            git("read-tree", f"--prefix={VERSIONS_DIR}/", base_versions_tree, root=root, env=env)
        blob = normalized_manifest(root, commit, version, port_version)
        git("update-index", "--add", "--cacheinfo", f"100644,{blob},{MANIFEST}", root=root, env=env)
        return git("write-tree", root=root, env=env)


def copy_commit(root, commit, tree, parent):
    fields = git("log", "-1", "--no-show-signature",
                 "--pretty=format:%an%n%ae%n%aD%n%cn%n%ce%n%cD%n%B",
                 commit, root=root, binary=True).split(b"\n", 6)
    an, ae, ad, cn, ce, cd, message = fields
    env = {
        "GIT_AUTHOR_NAME": an.decode(), "GIT_AUTHOR_EMAIL": ae.decode(),
        "GIT_AUTHOR_DATE": ad.decode(), "GIT_COMMITTER_NAME": cn.decode(),
        "GIT_COMMITTER_EMAIL": ce.decode(), "GIT_COMMITTER_DATE": cd.decode(),
    }
    return git("commit-tree", tree, "-p", parent, root=root, stdin=message, env=env)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--root", default=".")
    ap.add_argument("--from", dest="base", required=True, help="the upstream port branch tip")
    ap.add_argument("--version", required=True)
    ap.add_argument("--port-version", required=True, type=int)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    root = args.root

    base = git("rev-parse", args.base, root=root)
    head = git("rev-parse", "HEAD", root=root)
    commits = git("rev-list", "--reverse", f"{base}..{head}", root=root).split()
    if not commits:
        print(head)
        return

    base_versions = git("rev-parse", "--verify", "--quiet", f"{base}:{VERSIONS_DIR}",
                        root=root, may_fail=True) or ""

    # The base is rebuilt the same way, so the first commit is judged against a
    # like-for-like tree instead of one still carrying upstream's version fields.
    parent = base
    parent_tree = rebuilt_tree(root, base, base_versions, args.version, args.port_version)
    dropped = []
    for commit in commits:
        tree = rebuilt_tree(root, commit, base_versions, args.version, args.port_version)
        subject = git("log", "-1", "--format=%s", commit, root=root)
        if tree == parent_tree:
            dropped.append((commit, subject))
            print(f"drop  {commit[:9]} {subject}", file=sys.stderr)
            continue
        parent = parent if args.dry_run else copy_commit(root, commit, tree, parent)
        parent_tree = tree
        print(f"keep  {commit[:9]} {subject}", file=sys.stderr)

    if not dropped:
        print(head)
        return
    print(f"{len(dropped)} commit(s) carried version bookkeeping only", file=sys.stderr)
    print(head if args.dry_run else parent)


if __name__ == "__main__":
    main()
