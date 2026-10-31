#!/usr/bin/env python3
"""Tag the tested manifest version without changing master; publish it idempotently."""
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


def tags():
    return sorted((tag for tag in git("tag", "--list", "v*").splitlines()
                   if VERSION.fullmatch(tag[1:])), key=lambda tag: version(tag[1:]))


def remote_head():
    return git("ls-remote", "origin", "refs/heads/master").split()[0]


def ancestor(commit, head):
    return run("git", "merge-base", "--is-ancestor", commit, head, check=False).returncode == 0


def remote_tag(tag):
    output = git("ls-remote", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
    refs = {ref: commit for commit, ref in (line.split() for line in output.splitlines())}
    return refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}", ""))


def failure_details(result):
    """Keep GitHub's rejection reason without logging credentials or unlimited output."""
    text = "\n".join(part.strip() for part in (result.stderr, result.stdout) if part.strip())
    for name in ("RELEASE_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"):
        if secret := os.environ.get(name):
            text = text.replace(secret, "[REDACTED]")
    text = re.sub(r"(https?://)[^\s/@]+@", r"\1[REDACTED]@", text)
    text = re.sub(r"\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]+", "[REDACTED]", text)
    text = re.sub(r"(?i)(authorization:\s*(?:basic|bearer)\s+)\S+", r"\1[REDACTED]", text)
    return text[-4096:] or "Git returned no rejection details."


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

    # Publication can fail after a successful tag push. Recover only a tag that
    # actually exists remotely and points to this exact tested source.
    for tag in reversed(all_tags):
        commit = git("rev-parse", f"{tag}^{{commit}}")
        if commit == source and remote_tag(tag) == source:
            if manifest(git("show", f"{commit}:shard.yml")) != tag[1:]:
                raise ValueError("Existing release tag disagrees with its shard.yml")
            if not ancestor(commit, head):
                raise ValueError("Existing release tag is not on master")
            return {"tag": tag, "latest": tag == all_tags[-1], "recovered": True}

    if head != source:
        return {"tag": "", "reason": "master advanced; its newer CI run owns the release"}
    reachable = [tag for tag in all_tags if ancestor(tag, source)]
    previous = reachable[-1] if reachable else None
    value = manifest(Path("shard.yml").read_text())
    if previous:
        if version(value) < version(previous[1:]):
            raise ValueError("shard.yml is older than the latest release; prepare a newer version in a reviewed PR")
        if value == previous[1:]:
            return {"tag": "", "reason": "manifest version already released; no new release requested"}
    tag = "v" + value
    if tag in all_tags:
        raise ValueError("Declared tag already exists on a different commit; refusing to move it")
    result = {"tag": tag, "latest": not all_tags or version(value) > version(all_tags[-1][1:]), "recovered": False}
    if dry_run:
        return result

    # Never create an untested version-only child or push the protected branch.
    # A master advance after this check cannot make the tag point at untested code.
    git("tag", tag, source)
    pushed = run("git", "push", "origin", f"refs/tags/{tag}", check=False)
    if pushed.returncode:
        if remote_tag(tag) == source:
            return {**result, "recovered": True}  # accepted push, lost acknowledgement
        git("tag", "-d", tag)  # a local-only tag must not masquerade as a release on retry
        raise RuntimeError(
            "Release tag push was refused; master was not changed.\n"
            f"{failure_details(pushed)}\n"
            "Check Actions contents:write permission and release-tag rules. "
            "Do not disable CodeQL or bypass master protection. See docs/releasing.md."
        )
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
