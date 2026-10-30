# Automatic releases

Each push to `master` that passes the existing Redis/worker/connection test matrix
and the release lifecycle tests publishes a stable GitHub release with generated
notes. Pull requests test the automation but cannot publish. This is a source
shard release; it does not upload a binary or publish to another package registry.

## Version policy

- With no stable `vMAJOR.MINOR.PATCH` tags, publish the version already declared
  in `shard.yml`. Historical pre-release commits do not unexpectedly bump it.
- Otherwise, make one patch bump from the highest stable tag reachable from the
  tested commit, regardless of how many commits were merged.
- `(MINOR)` anywhere in those commit subjects/bodies makes a minor bump;
  `(MAJOR)` takes precedence and makes a major bump, including `0.x` to `1.0.0`.
- A deliberately higher version in `shard.yml` is preserved, never downgraded.
  Prerelease tags are not stable release baselines.
- Include the marker in the squash commit message when squash merging. Without
  it, a feature PR receives the ordinary patch bump.

The job updates `shard.yml`, commits `chore: bump version to X.Y.Z [skip ci]`,
and atomically pushes that commit and its `vX.Y.Z` tag. If the manifest already
contains the computed version, it tags the tested commit directly. The Crystal
`VERSION` constant reads that manifest at compile time; it needs no separate
manual update. `[skip ci]` and the release condition prevent a release loop.
Only the version line may differ from the tested source in the generated commit.

## Permissions and protection

Test jobs retain read-only repository permissions. Only the release job receives
`contents: write`. No additional token is needed when repository rules permit
GitHub Actions to push the version bump.

If branch rules reject that push, configure the repository Actions secret
`RELEASE_TOKEN`, as in Azu: a fine-grained token with repository Contents read/write,
owned by an account explicitly allowed to bypass the applicable rules. Do not
weaken protection for every actor or place a token in source control. The checkout
uses this token for Git pushes; GitHub release publication uses the job's
`GITHUB_TOKEN`. Actions must be enabled for push events on master.

## Ordering and recovery

Workflow runs serialize per branch without cancellation. If master has advanced
beyond the tested commit, the old run publishes nothing and the newer successful
run owns the release. The atomic push protects against a concurrent update or
branch-rule failure leaving an orphan tag. Existing tags are never rewritten.

If GitHub release creation fails after the tag was pushed, **rerun the failed
release job**. It verifies that the tag points to the original tested commit or
its version-only child, then publishes the missing release without another bump.
Repeated publication is a no-op. Recovering an older tag does not mark it latest
when a newer stable tag exists. A contradictory tag/manifest or unrelated tag
collision fails rather than overwriting history.

## Local validation

```sh
python3 .github/scripts/test_release.py
```

The tests create disposable local bare Git remotes and stub GitHub publication.
They exercise first releases, patch/minor/major selection, explicit versions,
retry recovery, stale runs, concurrent pushes, protection rejection, publication
failure and tag consistency. They never push to GitHub or publish a real release.
The release job depends on this check as well as every existing matrix result.
