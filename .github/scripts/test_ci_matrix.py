import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text()


def version(text):
    return tuple(int(part) for part in text.split("."))


WORKFLOW = read(".github/workflows/ci.yml")
SPECS_REDIS = re.findall(r'\{redis: "([\d.]+)", connection: \w+\}', WORKFLOW)
CRYSTAL_LEGS = [leg.strip().strip('"') for leg in re.search(r"crystal: \[(.*?)\]", WORKFLOW)[1].split(",")]
CRYSTAL_IMAGE = re.search(r"FROM crystallang/crystal:([\d.]+)-alpine", read(".github/ci-image/Dockerfile"))[1]


class CiMatrixMatchesTheClaims(unittest.TestCase):
    """CI tests what the README, CLAUDE.md and docs/reference/compatibility.md say it tests, and nothing is claimed untested."""

    def test_the_redis_legs_are_versions_the_fixture_can_build(self):
        buildable = set(re.findall(r"'(\d+\.\d+\.\d+)':", read("scripts/install_test_redis.py")))
        env = re.search(r'REDIS_VERSION: "([\d.]+)"', WORKFLOW)[1]
        self.assertGreaterEqual(len(set(SPECS_REDIS)), 3, "the floor, a 7.x and the newest")
        for redis in set(SPECS_REDIS) | {env}:
            self.assertIn(redis, buildable)
        self.assertEqual(max(SPECS_REDIS, key=version), env, "REDIS_VERSION is the newest tested Redis")

    def test_the_redis_floor_claimed_is_the_oldest_leg(self):
        floor = min(SPECS_REDIS, key=version)
        major_minor = ".".join(floor.split(".")[:2])
        claims = {
            "README.md": rf"\*\*Redis\*\* {re.escape(major_minor)} or newer",
            "CLAUDE.md": rf"\*\*Redis:\*\* {re.escape(major_minor)}\+",
            "src/joobq/redis_store.cr": rf"JoobQ needs Redis {re.escape(major_minor)} or newer",
        }
        for path, pattern in claims.items():
            self.assertRegex(read(path), pattern, f"{path} must claim the Redis floor CI tests ({major_minor})")

    def test_every_tested_redis_and_crystal_is_stated_where_users_read(self):
        compatibility, claude, readme = read("docs/reference/compatibility.md"), read("CLAUDE.md"), read("README.md")
        for redis in set(SPECS_REDIS):
            self.assertIn(redis, compatibility)
            self.assertIn(redis, claude)
            self.assertIn(".".join(redis.split(".")[:2]), readme)
        for crystal in set(CRYSTAL_LEGS) | {CRYSTAL_IMAGE}:
            self.assertIn(crystal, compatibility)
            self.assertIn(crystal, claude)
            self.assertIn(crystal, readme)

    def test_the_crystal_floor_in_shard_yml_is_tested_and_latest_is_too(self):
        floor = re.search(r'^crystal: ">= ([\d.]+)"', read("shard.yml"), re.M)[1]
        pinned = [leg for leg in CRYSTAL_LEGS if leg != "latest"]
        self.assertEqual(floor, min(pinned, key=version), "the oldest Crystal leg is the declared floor")
        self.assertIn("latest", CRYSTAL_LEGS)
        self.assertIn(floor, read(".tool-versions"))
        self.assertRegex(read("README.md"), rf"\*\*Crystal\*\* {re.escape(floor)} or newer")
        self.assertRegex(read("CLAUDE.md"), rf"\*\*Crystal:\*\* {re.escape(floor)}\+")

    def test_the_crystal_legs_install_the_packages_of_the_ci_image(self):
        image = re.search(r"apk add --no-cache ([\w+\- ]+)$", read(".github/ci-image/Dockerfile"), re.M)[1].split()
        leg = re.search(r'packages="([\w+\- ]+)"', WORKFLOW)[1].split()
        self.assertEqual(sorted(image), sorted(leg))

    def test_the_release_waits_for_every_specs_job(self):
        release = WORKFLOW[WORKFLOW.index("  release:"):]
        for job in ("specs", "crystal"):
            self.assertIn(f"needs.{job}.result == 'success'", release)
        self.assertRegex(release, r"needs: \[changes, specs, crystal\]")


if __name__ == "__main__":
    unittest.main()
