#!/usr/bin/env python3
"""Prepare an atomic, CI-gated shard release; publish it idempotently with gh."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
MANIFEST = re.compile(r"^version: ([0-9]+\.[0-9]+\.[0-9]+)[ \t]*$", re.MULTILINE)


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True)


def git(*args):
    return run("git", *args).stdout.strip()


def version(value):
    if not VERSION.fullmatch(value):
        raise ValueError(f"Not a stable semantic version: {value!r}")
    return tuple(map(int, value.split(".")))


def manifest(text):
    matches = MANIFEST.findall(text)
    if len(matches) != 1:
        raise ValueError("shard.yml must declare exactly one unquoted version: major.minor.patch")
    version(matches[0])
    return matches[0]


def next_version(declared, previous, messages):
    # A repository with no tags publishes its declared version, not 0.0.1 or a
    # bump inferred from its entire pre-release development history.
    if previous is None:
        return declared
    major, minor, patch = version(previous)
    if "(MAJOR)" in messages:
        candidate = (major + 1, 0, 0)
    elif "(MINOR)" in messages:
        candidate = (major, minor + 1, 0)
    else:
        candidate = (major, minor, patch + 1)
    return ".".join(map(str, max(candidate, version(declared))))


def tags():
    return sorted((tag for tag in git("tag", "--list", "v*").splitlines()
                   if VERSION.fullmatch(tag[1:])), key=lambda tag: version(tag[1:]))


def remote_head():
    return git("ls-remote", "origin", "refs/heads/master").split()[0]


def ancestor(commit, head):
    return run("git", "merge-base", "--is-ancestor", commit, head, check=False).returncode == 0


def bump_message(value):
    return f"chore: bump version to {value} [skip ci]"


def prepare(source, dry_run=False):
    if os.environ.get("GITHUB_EVENT_NAME") != "push" or os.environ.get("GITHUB_REF") != "refs/heads/master":
        raise ValueError("Releases are only allowed for a push to master")
    if not re.fullmatch(r"[0-9a-f]{40}", source) or git("rev-parse", "HEAD") != source:
        raise ValueError("Checkout must be the exact commit tested by this workflow")
    if git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Tracked files must be clean before release")
    git("fetch", "origin", "master", "--tags")
    all_tags = tags()
    head = remote_head()

    # A previous attempt may have pushed the bump/tag but failed to publish the
    # GitHub release. Accept only that exact source or a verified version-only child.
    for tag in reversed(all_tags):
        commit = git("rev-parse", f"{tag}^{{commit}}")
        parents = git("show", "-s", "--format=%P", commit).split()
        version_child = (parents == [source]
                         and git("show", "-s", "--format=%s", commit) == bump_message(tag[1:])
                         and git("diff", "--name-only", source, commit).splitlines() == ["shard.yml"])
        if commit == source or version_child:
            if manifest(git("show", f"{commit}:shard.yml")) != tag[1:]:
                raise ValueError("Existing release tag disagrees with its shard.yml")
            if not ancestor(commit, head):
                raise ValueError("Existing release tag is not on master")
            return {"tag": tag, "latest": tag == all_tags[-1], "recovered": True}

    if head != source:
        return {"tag": "", "reason": "master advanced; its newer CI run owns the release"}
    reachable = [tag for tag in all_tags if ancestor(tag, source)]
    previous = reachable[-1] if reachable else None
    declared = manifest(Path("shard.yml").read_text())
    messages = git("log", "--format=%B", f"{previous}..{source}") if previous else ""
    value = next_version(declared, previous[1:] if previous else None, messages)
    tag = "v" + value
    if tag in all_tags:
        raise ValueError("Calculated tag already exists on a different commit; refusing to move it")
    result = {"tag": tag, "latest": not all_tags or version(value) > version(all_tags[-1][1:]), "recovered": False}
    if dry_run:
        return result

    text = Path("shard.yml").read_text()
    Path("shard.yml").write_text(MANIFEST.sub(f"version: {value}", text))
    git("config", "user.name", "github-actions[bot]")
    git("config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
    if git("diff", "--name-only", "--", "shard.yml"):
        git("add", "shard.yml")
        git("commit", "-m", bump_message(value), "--", "shard.yml")
    git("tag", tag)
    # A non-fast-forward or protection rejection cannot leave an orphan tag.
    pushed = run("git", "push", "--atomic", "origin", "HEAD:refs/heads/master", f"refs/tags/{tag}", check=False)
    if pushed.returncode:
        if remote_head() != source:
            return {"tag": "", "reason": "master advanced during push; newer CI owns the release"}
        raise RuntimeError("Atomic release push was refused. Check branch rules and RELEASE_TOKEN; no tag was published.")
    return result


def publish(tag, latest):
    version(tag.removeprefix("v"))
    if not tag.startswith("v"):
        raise ValueError("Expected a v-prefixed release tag")
    if run("gh", "release", "view", tag, check=False).returncode == 0:
        print(f"{tag} already has a GitHub release")
        return
    created = run("gh", "release", "create", tag, "--verify-tag", "--generate-notes",
                  "--title", f"Release {tag}", "--latest" if latest else "--latest=false", check=False)
    # Concurrent publication or an ambiguous HTTP response can still have succeeded.
    if created.returncode and run("gh", "release", "view", tag, check=False).returncode:
        raise RuntimeError("GitHub release creation failed; rerun the failed release job to recover its existing tag")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--publish", metavar="TAG")
    parser.add_argument("--latest", choices=("true", "false"), default="true")
    args = parser.parse_args()
    if args.publish:
        if args.dry_run:
            raise ValueError("--dry-run cannot publish")
        publish(args.publish, args.latest == "true")
    else:
        result = prepare(os.environ.get("GITHUB_SHA", ""), args.dry_run)
        print(json.dumps(result))
        output = os.environ.get("GITHUB_OUTPUT")
        if output and not args.dry_run:
            with open(output, "a") as file:
                file.write(f"tag={result['tag']}\nlatest={str(result.get('latest', False)).lower()}\n")


if __name__ == "__main__":
    main()
