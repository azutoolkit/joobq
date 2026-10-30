#!/usr/bin/env python3
"""Release lifecycle tests use disposable local Git remotes, never GitHub."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class Versions(unittest.TestCase):
    def test_first_release_uses_declared_version(self):
        self.assertEqual(release.next_version("0.2.0", None, "(MAJOR) historic work"), "0.2.0")

    def test_one_bump_for_all_commits_since_tag(self):
        self.assertEqual(release.next_version("0.4.2", "0.5.1", "fix\nfix\nfix"), "0.5.2")
        self.assertEqual(release.next_version("0.5.1", "0.5.1", "(MINOR) one\n(MINOR) two"), "0.6.0")
        self.assertEqual(release.next_version("0.5.1", "0.5.1", "body\n(MAJOR)\n(MINOR)"), "1.0.0")

    def test_explicit_version_is_not_downgraded(self):
        self.assertEqual(release.next_version("1.0.0", "0.5.1", "ordinary merge"), "1.0.0")

    def test_invalid_and_duplicate_manifest_versions_fail(self):
        for text in ("version: nope", "version: 01.2.3", "version: 1.2.3\nversion: 1.2.4"):
            with self.assertRaises(ValueError):
                release.manifest(text)


class GitLifecycle(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.original = Path.cwd()
        self.remote = self.root / "origin.git"
        self.work = self.root / "work"
        subprocess.run(["git", "init", "--bare", "--initial-branch=master", str(self.remote)], check=True, capture_output=True)
        subprocess.run(["git", "clone", str(self.remote), str(self.work)], check=True, capture_output=True)
        os.chdir(self.work)
        release.git("config", "user.name", "Release test")
        release.git("config", "user.email", "test@example.invalid")
        Path("shard.yml").write_text("name: fixture\nversion: 0.2.0\n\nauthors: []\n")
        release.git("add", ".")
        release.git("commit", "-m", "Initial source")
        release.git("push", "origin", "HEAD:master")
        self.env = patch.dict(os.environ, {"GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/master"})
        self.env.start()

    def tearDown(self):
        self.env.stop()
        os.chdir(self.original)
        self.temporary.cleanup()

    def change(self, message="Fix jobs"):
        Path("source.cr").write_text(message)
        release.git("add", "source.cr")
        release.git("commit", "-m", message)
        release.git("push", "origin", "HEAD:master")
        return release.git("rev-parse", "HEAD")

    def baseline(self):
        release.git("tag", "v0.2.0")
        release.git("push", "origin", "refs/tags/v0.2.0")
        return self.change()

    def test_first_release_tags_tested_source(self):
        source = release.git("rev-parse", "HEAD")
        result = release.prepare(source)
        self.assertEqual(result["tag"], "v0.2.0")
        self.assertEqual(release.git("rev-parse", "v0.2.0"), source)
        self.assertTrue(release.prepare(source)["recovered"])

    def test_bump_and_tag_are_consistent_and_retry_recovers(self):
        source = self.baseline()
        result = release.prepare(source)
        self.assertEqual(result["tag"], "v0.2.1")
        self.assertEqual(release.manifest(release.git("show", "v0.2.1:shard.yml")), "0.2.1")
        self.assertEqual(release.git("diff", "--name-only", source, "v0.2.1"), "shard.yml")
        self.assertEqual(release.remote_head(), release.git("rev-parse", "v0.2.1"))
        self.assertIn("[skip ci]", release.git("log", "-1", "--format=%s"))
        release.git("checkout", "--detach", source)
        retry = release.prepare(source)
        self.assertTrue(retry["recovered"])
        self.assertEqual(retry["tag"], result["tag"])

    def test_stale_source_cannot_release_newer_untested_code(self):
        source = self.baseline()
        self.change("Newer source")
        release.git("checkout", "--detach", source)
        self.assertEqual(release.prepare(source)["tag"], "")
        self.assertEqual(release.tags(), ["v0.2.0"])

    def test_rejected_master_push_does_not_publish_tag(self):
        source = self.baseline()
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "Atomic release push was refused"):
            release.prepare(source)
        self.assertEqual(release.remote_head(), source)
        self.assertEqual(release.git("ls-remote", "origin", "refs/tags/v0.2.1"), "")

    def test_race_between_check_and_push_does_not_publish_tag(self):
        source = self.baseline()
        original_run = release.run
        def race(*args, **kwargs):
            if args[:3] == ("git", "push", "--atomic"):
                # Advance master with a sibling before the atomic transaction.
                sibling = subprocess.run(["git", "commit-tree", f"{source}^{{tree}}", "-p", source, "-m", "Concurrent source"], check=True, text=True, capture_output=True).stdout.strip()
                subprocess.run(["git", "push", "origin", f"{sibling}:master"], check=True, capture_output=True)
            return original_run(*args, **kwargs)
        with patch.object(release, "run", race):
            self.assertEqual(release.prepare(source)["tag"], "")
        self.assertEqual(release.git("ls-remote", "origin", "refs/tags/v0.2.1"), "")

    def test_old_retry_does_not_mark_itself_latest(self):
        source = self.baseline()
        release.prepare(source)
        newer = self.change("(MINOR) next feature")
        release.prepare(newer)
        release.git("checkout", "--detach", source)
        recovered = release.prepare(source)
        self.assertEqual(recovered["tag"], "v0.2.1")
        self.assertFalse(recovered["latest"])

    def test_dry_run_changes_no_refs_or_files(self):
        source = self.baseline()
        self.assertEqual(release.prepare(source, dry_run=True)["tag"], "v0.2.1")
        self.assertEqual(release.git("status", "--porcelain"), "")
        self.assertEqual(release.tags(), ["v0.2.0"])
        self.assertEqual(release.remote_head(), source)

    def test_pull_requests_and_wrong_checkout_cannot_release(self):
        source = self.baseline()
        with patch.dict(os.environ, {"GITHUB_EVENT_NAME": "pull_request"}):
            with self.assertRaises(ValueError):
                release.prepare(source)
        with self.assertRaises(ValueError):
            release.prepare("0" * 40)

    def test_existing_tag_must_match_its_manifest(self):
        source = release.git("rev-parse", "HEAD")
        release.git("tag", "v9.0.0")
        release.git("push", "origin", "refs/tags/v9.0.0")
        with self.assertRaisesRegex(ValueError, "disagrees"):
            release.prepare(source)


class Publication(unittest.TestCase):
    def result(self, code):
        return subprocess.CompletedProcess([], code, "", "")

    def test_existing_release_is_not_duplicated(self):
        with patch.object(release, "run", return_value=self.result(0)) as call:
            release.publish("v1.0.0", True)
            self.assertEqual(call.call_count, 1)

    def test_publication_uses_existing_tag_and_generated_notes(self):
        with patch.object(release, "run", side_effect=[self.result(1), self.result(0)]) as call:
            release.publish("v0.2.1", False)
            command = call.call_args_list[1].args
            self.assertIn("--verify-tag", command)
            self.assertIn("--generate-notes", command)
            self.assertIn("--latest=false", command)

    def test_ambiguous_success_is_rechecked_and_failures_propagate(self):
        with patch.object(release, "run", side_effect=[self.result(1), self.result(1), self.result(0)]):
            release.publish("v1.0.0", True)
        with patch.object(release, "run", return_value=self.result(1)):
            with self.assertRaises(RuntimeError):
                release.publish("v1.0.0", True)


if __name__ == "__main__":
    unittest.main()
