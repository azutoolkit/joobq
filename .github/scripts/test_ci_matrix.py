import re
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text()


def version(text):
    return tuple(int(part) for part in text.split("."))


def minor(text):
    return ".".join(text.split(".")[:2])


WORKFLOW = yaml.safe_load(read(".github/workflows/ci.yml"))
JOBS = WORKFLOW["jobs"]
NEWEST_REDIS = WORKFLOW["env"]["REDIS_VERSION"]
SPEC_LEGS = JOBS["specs"]["strategy"]["matrix"]["include"]
SPECS_REDIS = sorted({leg["redis"] for leg in SPEC_LEGS}, key=version)
CRYSTAL_LEGS = [str(leg) for leg in JOBS["crystal"]["strategy"]["matrix"]["crystal"]]
PINNED_CRYSTAL = [leg for leg in CRYSTAL_LEGS if leg != "latest"]
CRYSTAL_IMAGE = re.search(r"FROM crystallang/crystal:([\d.]+)-alpine", read(".github/ci-image/Dockerfile"))[1]


def bullet(path, label):
    """The README or CLAUDE.md line that states a requirement: the sentence users read, not a substring."""
    return re.search(rf"^- \*\*{label}\*\*.*$", read(path), re.M)[0]


def versions_after_ci_tests(line):
    tested = re.search(r"CI tests (.*?)(?:[;,]? on |\)|$)", line)[1]
    return set(re.findall(r"\d+\.\d+(?:\.\d+)?", tested))


class CiMatrixMatchesTheClaims(unittest.TestCase):
    """CI tests what the README, CLAUDE.md and docs/reference/compatibility.md say it tests, and nothing is claimed untested."""

    def test_the_redis_legs_are_versions_the_fixture_can_build(self):
        buildable = set(re.findall(r"'(\d+\.\d+\.\d+)':", read("scripts/install_test_redis.py")))
        self.assertGreaterEqual(len(SPECS_REDIS), 3, "the floor, a 7.x and the newest")
        self.assertLessEqual(set(SPECS_REDIS) | {NEWEST_REDIS}, buildable)
        self.assertEqual(SPECS_REDIS[-1], NEWEST_REDIS, "REDIS_VERSION is the newest tested Redis")

    def test_the_redis_floor_claimed_is_the_oldest_leg(self):
        floor = minor(SPECS_REDIS[0])
        self.assertRegex(bullet("README.md", "Redis"), rf"^- \*\*Redis\*\* {re.escape(floor)} or newer")
        self.assertRegex(bullet("CLAUDE.md", "Redis:"), rf"^- \*\*Redis:\*\* {re.escape(floor)}\+")
        self.assertIn(f"JoobQ needs Redis {floor} or newer", read("src/joobq/redis_store.cr"))

    def test_the_sentences_users_read_list_exactly_what_is_tested(self):
        readme_redis = versions_after_ci_tests(bullet("README.md", "Redis"))
        self.assertEqual({minor(redis) for redis in SPECS_REDIS}, readme_redis)
        readme_crystal = versions_after_ci_tests(bullet("README.md", "Crystal"))
        self.assertEqual(set(PINNED_CRYSTAL) | {CRYSTAL_IMAGE}, readme_crystal)
        self.assertIn("latest", bullet("README.md", "Crystal"))
        claude = read("CLAUDE.md")
        for tested in SPECS_REDIS + PINNED_CRYSTAL + [CRYSTAL_IMAGE]:
            self.assertIn(tested, claude)
            self.assertIn(tested, read("docs/reference/compatibility.md"))
        self.assertIn("reported, not gating", claude)
        self.assertIn("reported, not gating", read("docs/reference/compatibility.md"))

    def test_the_crystal_floor_in_shard_yml_is_tested_and_latest_is_too(self):
        floor = re.search(r'^crystal: ">= ([\d.]+)"', read("shard.yml"), re.M)[1]
        self.assertEqual(floor, min(PINNED_CRYSTAL, key=version), "the oldest Crystal leg is the declared floor")
        self.assertIn("latest", CRYSTAL_LEGS)
        self.assertIn(floor, read(".tool-versions"))
        self.assertRegex(bullet("README.md", "Crystal"), rf"^- \*\*Crystal\*\* {re.escape(floor)} or newer")
        self.assertRegex(bullet("CLAUDE.md", "Crystal:"), rf"^- \*\*Crystal:\*\* {re.escape(floor)}\+")

    def test_the_crystal_job_runs_the_newest_redis_on_the_legacy_connection(self):
        runs = [step for step in JOBS["crystal"]["steps"] if step.get("uses") == "./.github/actions/run-specs"]
        self.assertEqual(1, len(runs))
        self.assertEqual("${{ env.REDIS_VERSION }}", runs[0]["with"]["redis"])
        self.assertEqual("legacy", runs[0]["with"]["connection"])

    def test_the_crystal_legs_install_the_packages_of_the_ci_image(self):
        image = re.search(r"apk add --no-cache ([\w+\- ]+)$", read(".github/ci-image/Dockerfile"), re.M)[1].split()
        install = next(step["run"] for step in JOBS["crystal"]["steps"] if step.get("name") == "System packages")
        self.assertEqual(sorted(image), sorted(re.search(r'packages="([\w+\- ]+)"', install)[1].split()))

    def test_the_release_waits_for_the_specs_and_the_floor_but_not_for_latest(self):
        release = JOBS["release"]
        self.assertEqual(["changes", "specs", "crystal"], release["needs"])
        for job in ("specs", "crystal"):
            self.assertIn(f"needs.{job}.result == 'success'", release["if"])
        self.assertNotIn("continue-on-error", JOBS["specs"])
        # a failed `latest` leg leaves the job green (and the run a valid last_tested baseline); the floor leg stays gating
        self.assertEqual("${{ matrix.crystal == 'latest' }}", JOBS["crystal"]["continue-on-error"])
        self.assertEqual("latest", [leg for leg in CRYSTAL_LEGS if leg not in PINNED_CRYSTAL][0])


if __name__ == "__main__":
    unittest.main()
