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

    def change(self, message="Fix jobs", declared=None):
        Path("source.cr").write_text(message)
        if declared is not None:
            text = Path("shard.yml").read_text()
            Path("shard.yml").write_text(release.MANIFEST.sub(f"version: {declared}", text))
        release.git("add", "source.cr", "shard.yml")
        release.git("commit", "-m", message)
        release.git("push", "origin", "HEAD:master")
        return release.git("rev-parse", "HEAD")

    def baseline(self, declared="0.2.1"):
        release.git("tag", "v0.2.0")
        release.git("push", "origin", "refs/tags/v0.2.0")
        return self.change(declared=declared)

    def test_first_release_tags_tested_source(self):
        source = release.git("rev-parse", "HEAD")
        result = release.prepare(source)
        self.assertEqual(result["tag"], "v0.2.0")
        self.assertEqual(release.git("rev-parse", "v0.2.0"), source)
        self.assertTrue(release.prepare(source)["recovered"])

    def test_declared_version_tags_exact_tested_commit_and_retry_recovers(self):
        source = self.baseline()
        result = release.prepare(source)
        self.assertEqual(result["tag"], "v0.2.1")
        self.assertEqual(release.manifest(release.git("show", "v0.2.1:shard.yml")), "0.2.1")
        self.assertEqual(release.git("rev-parse", "v0.2.1"), source)
        self.assertEqual(release.remote_head(), source)
        self.assertEqual(release.git("status", "--porcelain"), "")
        self.assertTrue(release.prepare(source)["recovered"])

    def test_unchanged_version_does_not_infer_a_bump_from_messages(self):
        self.baseline("0.2.0")
        source = self.change("(MAJOR) (MINOR) documentation")
        self.assertEqual(release.prepare(source)["tag"], "")
        self.assertEqual(release.tags(), ["v0.2.0"])

    def test_manifest_downgrade_is_rejected(self):
        source = self.baseline("0.1.9")
        with self.assertRaisesRegex(ValueError, "older than the latest release"):
            release.prepare(source)

    def test_explicit_major_version_is_preserved(self):
        source = self.baseline("1.0.0")
        self.assertEqual(release.prepare(source)["tag"], "v1.0.0")
        self.assertEqual(release.git("rev-parse", "v1.0.0"), source)

    def test_stale_source_cannot_release_newer_untested_code(self):
        source = self.baseline()
        self.change("Newer source")
        release.git("checkout", "--detach", source)
        self.assertEqual(release.prepare(source)["tag"], "")
        self.assertEqual(release.tags(), ["v0.2.0"])

    def test_protected_master_needs_no_bypass_for_release(self):
        source = self.baseline()
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nwhile read old new ref; do\n"
                        "  if [ \"$ref\" = refs/heads/master ]; then\n"
                        "    echo 'GH013: Code scanning results are required' >&2; exit 1\n"
                        "  fi\ndone\n")
        hook.chmod(0o755)
        self.assertEqual(release.prepare(source)["tag"], "v0.2.1")
        self.assertEqual(release.remote_head(), source)
        self.assertEqual(release.remote_tag("v0.2.1"), source)

    def test_rejected_tag_push_cleans_local_tag_and_can_retry(self):
        source = self.baseline()
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\necho 'GH013: Tag creation refused' >&2\nexit 1\n")
        hook.chmod(0o755)
        with self.assertRaisesRegex(RuntimeError, "GH013: Tag creation refused"):
            release.prepare(source)
        self.assertEqual(release.remote_head(), source)
        self.assertEqual(release.remote_tag("v0.2.1"), "")
        self.assertNotIn("v0.2.1", release.tags())
        hook.unlink()
        self.assertFalse(release.prepare(source)["recovered"])
        self.assertEqual(release.remote_tag("v0.2.1"), source)

    def test_race_cannot_tag_newer_untested_code_or_overwrite_master(self):
        source = self.baseline()
        original_run = release.run
        def race(*args, **kwargs):
            if args[:3] == ("git", "push", "origin"):
                sibling = subprocess.run(["git", "commit-tree", f"{source}^{{tree}}", "-p", source, "-m", "Concurrent source"], check=True, text=True, capture_output=True).stdout.strip()
                subprocess.run(["git", "push", "origin", f"{sibling}:master"], check=True, capture_output=True)
            return original_run(*args, **kwargs)
        with patch.object(release, "run", race):
            self.assertEqual(release.prepare(source)["tag"], "v0.2.1")
        self.assertEqual(release.remote_tag("v0.2.1"), source)
        self.assertNotEqual(release.remote_head(), source)

    def test_lost_push_acknowledgement_recovers_remote_tag(self):
        source = self.baseline()
        original_run = release.run
        def ambiguous(*args, **kwargs):
            result = original_run(*args, **kwargs)
            if args[:3] == ("git", "push", "origin"):
                return subprocess.CompletedProcess(args, 1, "", "Connection closed after acceptance")
            return result
        with patch.object(release, "run", ambiguous):
            self.assertTrue(release.prepare(source)["recovered"])
        self.assertEqual(release.remote_tag("v0.2.1"), source)

    def test_existing_tag_on_other_history_is_not_overwritten(self):
        source = self.baseline()
        unrelated = release.git("commit-tree", f"{source}^{{tree}}", "-m", "Unrelated release")
        release.git("tag", "v0.2.1", unrelated)
        release.git("push", "origin", "refs/tags/v0.2.1")
        with self.assertRaisesRegex(ValueError, "different commit"):
            release.prepare(source)
        self.assertEqual(release.remote_tag("v0.2.1"), unrelated)

    def test_old_retry_does_not_mark_itself_latest(self):
        source = self.baseline()
        release.prepare(source)
        newer = self.change("Next feature", declared="0.3.0")
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

    def test_annotated_remote_tag_recovers_its_tested_commit(self):
        source = release.git("rev-parse", "HEAD")
        release.git("tag", "-a", "v0.2.0", "-m", "Released source")
        release.git("push", "origin", "refs/tags/v0.2.0")
        self.assertEqual(release.remote_tag("v0.2.0"), source)
        self.assertTrue(release.prepare(source)["recovered"])

    def test_uncommitted_manifest_is_never_released(self):
        source = self.baseline()
        Path("shard.yml").write_text("name: fixture\nversion: 1.0.0\n")
        with self.assertRaisesRegex(ValueError, "Tracked files must be clean"):
            release.prepare(source)
        self.assertEqual(release.remote_tag("v1.0.0"), "")

    def test_existing_tag_must_match_its_manifest(self):
        source = release.git("rev-parse", "HEAD")
        release.git("tag", "v9.0.0")
        release.git("push", "origin", "refs/tags/v9.0.0")
        with self.assertRaisesRegex(ValueError, "disagrees"):
            release.prepare(source)


class Diagnostics(unittest.TestCase):
    def test_push_diagnostics_redact_credentials(self):
        result = subprocess.CompletedProcess([], 1, "", "\n".join([
            "GH013: Code scanning results are required",
            "https://bot:password@github.com/owner/repo.git",
            "Authorization: basic encoded-credentials",
            "Authorization: Bearer opaque-bearer",
            "ghp_exampleToken github_pat_exampleToken opaque-secret",
        ]))
        with patch.dict(os.environ, {"RELEASE_TOKEN": "opaque-secret"}):
            detail = release.failure_details(result)
        self.assertIn("GH013: Code scanning results are required", detail)
        for secret in ("password", "encoded-credentials", "opaque-bearer", "ghp_exampleToken", "github_pat_exampleToken", "opaque-secret"):
            self.assertNotIn(secret, detail)

    def test_push_diagnostics_bound_output_and_handle_missing_stderr(self):
        result = subprocess.CompletedProcess([], 1, "x" * 5000 + "rejected", "")
        detail = release.failure_details(result)
        self.assertEqual(len(detail), 4096)
        self.assertTrue(detail.endswith("rejected"))
        self.assertEqual(release.failure_details(subprocess.CompletedProcess([], 1, "", "")),
                         "Git returned no rejection details.")


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
