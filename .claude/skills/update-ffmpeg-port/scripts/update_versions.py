#!/usr/bin/env python3
"""Edit the registry's version metadata.

Two modes, because the git-tree of ports/ffmpeg can only be computed once the
port itself is final:

  port      rewrite "version"/"port-version" in ports/ffmpeg/vcpkg.json, in
            place, touching nothing else about the file's formatting
  versions  put the published version in versions/f-/ffmpeg.json - the only
            entry it keeps - and point versions/baseline.json at it
"""
import argparse
import json
import re
import sys
from pathlib import Path

PORT_MANIFEST = "ports/ffmpeg/vcpkg.json"
VERSIONS_FILE = "versions/f-/ffmpeg.json"
BASELINE_FILE = "versions/baseline.json"


def read_json(path: Path):
    raw = path.read_text()
    return json.loads(raw), raw.endswith("\n")


def write_json(path: Path, data, trailing_newline: bool) -> None:
    # Both version files are vcpkg-style: 4-space indent, no trailing newline.
    text = json.dumps(data, indent=4) + ("\n" if trailing_newline else "")
    path.write_text(text)


def edit_port_manifest(root: Path, version: str, port_version: int) -> bool:
    path = root / PORT_MANIFEST
    raw = path.read_text()

    new, hits = re.subn(
        r'(?m)^(\s*"version"\s*:\s*)"[^"]*"',
        lambda m: m.group(1) + json.dumps(version),
        raw,
        count=1,
    )
    if hits != 1:
        sys.exit(f'{PORT_MANIFEST}: expected exactly one "version" key, found {hits}')

    new, hits = re.subn(
        r'(?m)^(\s*"port-version"\s*:\s*)\d+',
        lambda m: m.group(1) + str(port_version),
        new,
        count=1,
    )
    if hits == 0:
        # Upstream omits port-version when it is 0; insert it after "version".
        new, hits = re.subn(
            r'(?m)^(\s*)("version"\s*:\s*"[^"]*",)$',
            lambda m: f'{m.group(1)}{m.group(2)}\n{m.group(1)}"port-version": {port_version},',
            new,
            count=1,
        )
        if hits != 1:
            sys.exit(f"{PORT_MANIFEST}: could not insert a port-version key")

    # Upstream's manifest ends with a newline; keep it that way so the port stays
    # byte-identical to upstream outside the resolume delta.
    new = new.rstrip("\n") + "\n"

    # Parse-check before writing, so a bad regex can never land a broken manifest.
    parsed = json.loads(new)
    if parsed.get("version") != version or parsed.get("port-version") != port_version:
        sys.exit(f"{PORT_MANIFEST}: rewrite did not take effect")

    if new == raw:
        return False
    path.write_text(new)
    return True


def edit_versions(root: Path, version: str, port_version: int, git_tree: str) -> None:
    path = root / VERSIONS_FILE
    data, nl = read_json(path)

    # This registry keeps exactly one version: the one it is publishing.
    # Consumers follow a branch or tag of this repo and always take the newest,
    # and the entries of rounds we shipped ourselves do not survive re-pointing
    # that ref - so there is no history here worth naming or protecting.
    previous = data.get("versions") or []
    data["versions"] = [
        {"git-tree": git_tree, "version": version, "port-version": port_version}
    ]
    write_json(path, data, nl)
    dropped = [
        f"{e.get('version')}#{e.get('port-version', 0)}"
        for e in previous
        if (e.get("version"), e.get("port-version", 0)) != (version, port_version)
    ]
    if dropped:
        print(f"{VERSIONS_FILE}: dropped {len(dropped)} superseded entr"
              f"{'y' if len(dropped) == 1 else 'ies'} ({', '.join(dropped[:6])}"
              f"{', ...' if len(dropped) > 6 else ''})")

    path = root / BASELINE_FILE
    data, nl = read_json(path)
    port = data.setdefault("default", {}).setdefault("ffmpeg", {})
    port["baseline"] = version
    port["port-version"] = port_version
    write_json(path, data, nl)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mode", choices=["port", "versions"])
    ap.add_argument("--root", default=".", help="registry checkout root")
    ap.add_argument("--version", required=True)
    ap.add_argument("--port-version", required=True, type=int)
    ap.add_argument("--git-tree", help="required for mode=versions")
    args = ap.parse_args()

    root = Path(args.root)
    if args.mode == "port":
        changed = edit_port_manifest(root, args.version, args.port_version)
        print(f"{PORT_MANIFEST}: {'updated' if changed else 'already correct'} "
              f"({args.version} port-version {args.port_version})")
    else:
        if not re.fullmatch(r"[0-9a-f]{40}", args.git_tree or ""):
            sys.exit("mode=versions needs --git-tree <40-hex sha>")
        edit_versions(root, args.version, args.port_version, args.git_tree)
        print(f"{VERSIONS_FILE} + {BASELINE_FILE}: {args.version} "
              f"port-version {args.port_version} git-tree {args.git_tree}")


if __name__ == "__main__":
    main()
