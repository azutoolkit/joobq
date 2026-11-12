import os
import subprocess
import tempfile
import unittest
from unittest import mock

import changed_paths
from changed_paths import classify


def groups(*paths):
    return sorted(group for group, needed in classify(paths).items() if needed)


class ChangedPaths(unittest.TestCase):
    def test_docs_only_runs_the_book_alone(self):
        self.assertEqual(["book"], groups("docs/how-to/install.md", "docs/SUMMARY.md"))
        self.assertEqual(["book"], groups(".gitbook.yaml"))
        self.assertEqual(["book"], groups("gitbook-docs.yaml"))

    def test_example_programs_run_the_book_and_the_examples(self):
        self.assertEqual(["book", "examples"], groups("examples/docs/core/first_job.cr"))

    def test_source_runs_the_specs_only(self):
        self.assertEqual(["code"], groups("src/joobq/worker.cr"))
        self.assertEqual(["code"], groups("shard.yml"))

    def test_files_nothing_reads_run_nothing(self):
        self.assertEqual([], groups("README.md", "CHANGELOG.md", "design/audit.md", "benchmarks/legacy.cr", ".claude/agents/x.md", ".github/ISSUE_TEMPLATE/bug_report.md"))

    def test_the_image_and_the_workflow_run_what_uses_them(self):
        self.assertEqual(["code", "examples", "image"], groups(".github/ci-image/TAG"))
        self.assertEqual(["book", "code", "examples"], groups(".github/workflows/ci.yml"))
        self.assertEqual(["code", "examples"], groups("scripts/install_test_redis.py"))

    def test_mixed_push_runs_each_group_once(self):
        self.assertEqual(["book", "code"], groups("src/joobq.cr", "docs/README.md"))


class ChangedSinceLastSuccess(unittest.TestCase):
    def setUp(self):
        self.origin = os.getcwd()
        self.addCleanup(os.chdir, self.origin)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        os.chdir(self.directory.name)
        self.git("init", "-q")

    def git(self, *argv):
        return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *argv], check=True,
                              capture_output=True, text=True).stdout.strip()

    def write(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as file:
            file.write(text)

    def test_renames_and_unusual_names_are_listed(self):
        self.write("src/worker.cr", "class Worker\nend\n")
        self.git("add", "-A"), self.git("commit", "-qm", "base")
        base = self.git("rev-parse", "HEAD")
        os.makedirs("design")
        self.git("mv", "src/worker.cr", "design/worker.cr")
        self.write("src/é.cr", "x\n")
        self.git("add", "-A"), self.git("commit", "-qm", "move")
        with mock.patch.object(changed_paths, "last_tested", return_value=base):
            paths = changed_paths.changed("HEAD")
        self.assertIn("src/worker.cr", paths)  # the deleted side of a rename is a code change
        self.assertIn("src/é.cr", paths)  # not C-quoted
        self.assertEqual(["code"], groups(*paths))

    def test_last_tested_asks_for_the_newest_successful_push_run(self):
        done = subprocess.CompletedProcess([], 0, stdout="abc123\n")
        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "o/r"}), mock.patch("subprocess.run", return_value=done) as run:
            self.assertEqual("abc123", changed_paths.last_tested())
        query = run.call_args.args[0][2]
        for part in ("o/r/actions/workflows/ci.yml/runs", "branch=master", "event=push", "status=success", "per_page=1"):
            self.assertIn(part, query)
        failed = subprocess.CompletedProcess([], 1, stdout="")
        with mock.patch.dict(os.environ, {"GITHUB_REPOSITORY": "o/r"}), mock.patch("subprocess.run", return_value=failed):
            self.assertIsNone(changed_paths.last_tested())
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(changed_paths.last_tested())

    def test_an_unknown_or_unrelated_base_means_run_everything(self):
        self.git("commit", "-q", "--allow-empty", "-m", "x")
        for base in (None, "1" * 40):
            with mock.patch.object(changed_paths, "last_tested", return_value=base):
                self.assertIsNone(changed_paths.changed("HEAD"))


if __name__ == "__main__":
    unittest.main()
