---
name: update-ffmpeg-port
description: Update this registry's ports/ffmpeg to an upstream microsoft/vcpkg tag or commit - pull the upstream subtree, replay the resolume customizations, refresh the version database, and prepare the PR branch. Use when asked to update, upgrade or re-sync the ffmpeg port against a vcpkg tag/commit/release.
---

# Update the ffmpeg port from upstream vcpkg

Automates the manual procedure in `README.md`. The user names an upstream
microsoft/vcpkg tag or commit (`2026.06.01`, `40dd49b0c9`, `master`); this skill
produces a verified `<label>-ffmpeg-update` branch ready for a PR.

**Input:** the vcpkg ref, as given (`/update-ffmpeg-port 2026.06.01`). If the
user did not name one, ask - do not pick a tag for them; `git -C <vcpkg-clone>
tag --sort=-creatordate | head` lists the candidates. `<label>` is that ref when
it is a date tag, otherwise its short sha, and it prefixes both branch names.

## What the repo looks like

This is a standalone vcpkg registry holding one port: a copy of upstream's
`ports/ffmpeg`, tracked as a git subtree, plus a small resolume delta on top.
Every round of this procedure keeps that shape:

```
<subtree merge>   upstream ports/ffmpeg exactly as of a vcpkg commit  <- ...-ffmpeg-port
     |
<resolume customizations>   4 patches + 3 portfile hunks + version files  <- ...-ffmpeg-update
```

The version database names one version: the one being published. Consumers point
at a branch or tag of this repo and always take the newest, so the versions this
registry shipped itself are not kept - `finish-update.sh` replaces the entries in
`versions/f-/ffmpeg.json` with the current one.

`master` is always the previous round in exactly this shape, so the previous
round is the reference for what the delta should look like. Read
`reference.md` (in this skill directory) before resolving any conflict - it
lists the delta line by line and the conventions the verifier enforces.

## Steps

Scripts live in `scripts/` next to this file; run them from anywhere inside the
repo. Each one prints what it did and what comes next, and they share state
through `.git/resolume-ffmpeg-update.env`.

**1. Extend the upstream subtree history** (seconds, unless it has to clone
vcpkg first):

```bash
.claude/skills/update-ffmpeg-port/scripts/split-upstream.sh <vcpkg-tag-or-commit>
```

It finds or clones a microsoft/vcpkg checkout (`--vcpkg PATH`, else
`$VCPKG_ROOT`, `~/develop/vcpkg`, or a cache clone), fetches, resolves the ref,
and copies the upstream commits that touch `ports/ffmpeg` onto the split history
this registry already merged, as branch `resolume-split/<label>`. It refuses to
go on if the requested ref does not contain what this registry is already on.
Exit code 3 means "already up to date" - report that and stop. Show the user the
list of new upstream commits and the version/port-version it reports.

The commits it writes are byte-identical to `git subtree split`'s (same trees,
authors, dates, messages, parents), which is why the next `git subtree pull`
fast-forwards. Do not reach for `--full-split` to "do it properly": it runs the
real `git subtree split` over all ~30k vcpkg commits, takes hours, and produces
the same shas.

**2. Pull the subtree and replay the customizations:**

```bash
.claude/skills/update-ffmpeg-port/scripts/start-update.sh
```

Creates `<label>-ffmpeg-port` (upstream only) and `<label>-ffmpeg-update`
(customizations rebased on top). Exit code 2 means the rebase stopped on
conflicts - resolve them per `reference.md`, `git rebase --continue`, then go on.
Conflicts in `portfile.cmake` and `vcpkg.json` are normal: upstream adds and
drops entries in the `PATCHES` list and reformats calls the resolume hunks sit
next to. One commit can conflict in several files, and `--continue` can stop
again on the next commit - after each resolution check `git ls-files -u` is empty
and read what `--continue` printed rather than assuming it succeeded.

**3. Version bookkeeping:**

```bash
.claude/skills/update-ffmpeg-port/scripts/finish-update.sh
```

Sets `version` to upstream's and `port-version` to upstream + 100, computes
`git rev-parse HEAD:ports/ffmpeg`, writes `versions/f-/ffmpeg.json` (the single
published entry) and `versions/baseline.json`, amends both into the resolume
commit, and runs the verifier. Fix anything it reports as FAIL before continuing.

It first drops any replayed commit whose remaining content is only version
bookkeeping - a port-version bump and nothing else. That is what a resolume
commit shrinks to once upstream absorbs it, and such a commit has nothing left to
say. It prints `drop`/`keep` per commit; relay which ones went and why (usually
"upstream now does this"). `--keep-bookkeeping-commits` turns it off.

**4. Check the resolume patches against the new ffmpeg source** (downloads the
ffmpeg tarball; skip only if there is no network, and say so if you skip):

```bash
.claude/skills/update-ffmpeg-port/scripts/check-patches.sh
```

A new ffmpeg release usually moves the context of the `1xxx` resolume patches.
If one only applies with fuzz or fails, refresh it using the recipe the script
prints, fold it into the resolume commit (`git add ports/ffmpeg/<patch> &&
git commit --amend --no-edit`), then re-run `finish-update.sh` (the git-tree
changes with the patch) and `check-patches.sh`.

**5. Report, then stop.** Summarise for the user: version and port-version,
new upstream commits pulled in, conflicts resolved, patches refreshed, and the
verifier's output. Then hand over - do not push or open a PR unless the user
asks for it in this session.

## Pushing and the PR (only when the user asks)

```bash
git push forpr <label>-ffmpeg-update
gh pr create --repo resolume/vcpkg-ffmpeg --base master \
  --head sandercox:<label>-ffmpeg-update \
  --title "Update ffmpeg to <version> from vcpkg <ref>" --body "..."
```

`forpr` is the fork (`sandercox/resolume-vcpkg-ffmpeg`); `origin`/`resolume`
point at `resolume/vcpkg-ffmpeg`. Never push to `origin`/`resolume` directly and
never force-push a shared branch. Tagging (`vcpkg-<date>` for the upstream
snapshot, a Resolume version number for the release that ships it) is the user's
call - mention it, do not do it.

## Rules

- **Never edit upstream content.** Outside the resolume delta, `ports/ffmpeg`
  must stay byte-identical to upstream. No reformatting, no reindenting, no
  reordering - the verifier warns when a diff shrinks under `-w`, and that noise
  makes every future update conflict.
- **The version database holds one entry.** Do not re-add the versions this
  registry shipped itself, and do not hand-edit the file - `finish-update.sh`
  writes it. An exact pin to an older resolume port-version stops resolving; that
  is accepted, since consumers follow a branch or tag and take the newest.
- The port-version offset is 100 (upstream `2` -> resolume `102`). Override only
  if the user asks: `finish-update.sh --port-version N`.
- Keep `resolume customizations` as the tip commit of `master`. Other commits on
  master (this skill, README edits) are replayed too and are harmless, but the
  version files get amended into whatever the tip happens to be; the scripts warn
  when that is not a commit touching the port.
- If the working tree is dirty or a rebase is already in progress, stop and ask -
  the scripts refuse to run and you should not clear the way on your own.
- Re-running a step is safe: `split-upstream.sh` reuses a cached split,
  `start-update.sh --force` recreates the branches, `finish-update.sh` and
  `verify.sh` are idempotent.
- When upstream has absorbed a resolume change, keep upstream's version and drop
  ours, even when ours is richer - a resolume block that shadows an upstream one
  is a latent bug (two `if("x" IN_LIST FEATURES)` blocks, a duplicate manifest
  key, a patch whose context is gone). Say what was dropped and what changes for
  the user because of it.
- Anything the scripts do not cover (a port-version that must skip a number, an
  upstream change that drops a patch the resolume patches build on) is a
  judgement call: explain it and ask.

## Verifying at any time

```bash
.claude/skills/update-ffmpeg-port/scripts/verify.sh                 # uses the update in progress
.claude/skills/update-ffmpeg-port/scripts/verify.sh --against <ref> # any branch vs any upstream ref
.claude/skills/update-ffmpeg-port/scripts/resolume-delta.sh --stat  # the previous round's delta
```
