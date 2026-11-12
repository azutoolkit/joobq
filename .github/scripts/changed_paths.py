#!/usr/bin/env python3
"""Decide which CI jobs a push needs from the files it changed.

Writes `code`, `book`, `examples` and `image` (true/false) to $GITHUB_OUTPUT. A path outside every group below
runs nothing: a new directory that the specs or the docs read must be added here. The files compared are those changed
since the last fully successful run (see last_tested). Anything unknowable (no such run, a rewritten history, a manual
run) runs everything; the CI image is rebuilt then only on a push to master, or when asked.
"""
import fnmatch
import os
import subprocess
import sys

WORKFLOW = ".github/workflows/ci.yml"
REDIS = ["scripts/install_test_redis.py", ".github/actions/pinned-redis/*"]
IMAGE = [".github/ci-image/*"]
GROUPS = {
    # specs, format check, Redis smoke and the release that follows them
    "code": ["src/*", "spec/*", "config/*", "shard.yml", "shard.lock", ".tool-versions", "scripts/run_integration.py",
             "scripts/redis_restart_smoke.py", "scripts/leased_process_probe.py", ".github/scripts/*", WORKFLOW] + REDIS + IMAGE,
    # docs/ navigation, links, markup, Git Sync files, and that the docs quote the examples verbatim
    "book": ["docs/*", "examples/docs/*", "scripts/check_docs.py", "scripts/test_check_docs.py", ".gitbook.yaml", "gitbook-docs.yaml", WORKFLOW],
    # the documentation programs, run against the released Core graph
    "examples": ["examples/docs/*", "scripts/test_docs_examples.py", WORKFLOW] + REDIS + IMAGE,
    "image": IMAGE,
}


def classify(paths):
    return {group: any(fnmatch.fnmatchcase(path, pattern) for path in paths for pattern in patterns) for group, patterns in GROUPS.items()}


def git(*argv):
    result = subprocess.run(["git", *argv], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def last_tested():
    """Head of the newest run of this workflow on master that fully succeeded.

    A run that passed certifies everything up to its own head, so comparing against it (not against the push's
    `before`) means files from a run that failed, was cancelled, was replaced while queued, or deferred its release (the
    release job fails then) are checked by the next run. Only push runs count: a manual run does not release.
    """
    repository = os.environ.get("GITHUB_REPOSITORY")
    if not repository:
        return None
    query = f"repos/{repository}/actions/workflows/ci.yml/runs?branch=master&event=push&status=success&per_page=1"
    found = subprocess.run(["gh", "api", query, "--jq", ".workflow_runs[0].head_sha // empty"], capture_output=True, text=True)
    return found.stdout.strip() if found.returncode == 0 else None


def changed(after):
    base = last_tested()
    if not base or git("merge-base", "--is-ancestor", base, after) is None:
        return None
    names = git("diff", "--name-only", "--no-renames", "-z", base, after)  # -z: no quoting of unusual names
    return names.split("\0") if names is not None else None


def main():
    event, after = os.environ.get("GITHUB_EVENT_NAME"), os.environ.get("AFTER", "HEAD")
    paths = changed(after) if event == "push" else None
    if paths is None:  # unknown history or a manual run: everything, and the image only when asked (or on a push)
        result = {group: True for group in GROUPS}
        result["image"] = event == "push" or os.environ.get("REBUILD_IMAGE") == "true"
    else:
        result = classify([path for path in paths if path])
    if os.environ.get("GITHUB_REF") != "refs/heads/master":
        result["image"] = False  # only master pushes the image, so no other ref may expect a new tag
    lines = [f"{group}={str(value).lower()}" for group, value in result.items()]
    tag = open(".github/ci-image/TAG").read().strip()
    lines.append(f"image_tag={tag}")
    print("\n".join(lines))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
