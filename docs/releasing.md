# Automatic releases

A push to `master` that passes the Redis/worker/connection matrix and release
lifecycle tests publishes the **new version already declared in `shard.yml`**.
CI tags the exact tested commit and creates a GitHub release with generated notes.
It never changes the manifest, creates a version-only commit, or pushes `master`.
Pull requests run the checks but cannot publish.

This is a source shard release. It does not upload a binary or publish to another
package registry.

## Prepare a release

1. Choose a stable semantic version greater than the latest released version.
2. Update the top-level `version:` in `shard.yml` in a normal pull request. For
   example, change `0.5.4` to `0.5.5` for a patch release. The runtime `VERSION`
   reads this manifest, so no separate source constant needs editing.
3. Let the PR pass its required checks and CodeQL, then review and merge it.
4. Let the resulting `master` run finish. Its release job creates `v0.5.5` at
   that tested commit, with the same version in the tagged manifest.
5. Verify the tag target and GitHub release. Do not rerun an old workflow that
   still contains the previous version-bump implementation to publish the fix.

Include the version change in the feature/fix PR or in a separate release PR.
Both squash and merge commits work: the manifest determines the version, not
commit subjects or bodies. `(MINOR)` and `(MAJOR)` no longer select versions.
Do not use `[skip ci]` on a release PR or merge commit.

## Version rules

- With no stable `vMAJOR.MINOR.PATCH` tags, publish the declared manifest version.
- A manifest newer than the highest stable tag reachable from the tested source
  requests a release. CI does not infer another bump or rewrite it.
- An unchanged version produces no release. Documentation and maintenance merges
  can therefore pass CI without publishing another version.
- A version older than that baseline fails with a request to prepare a newer
  version. A tag collision on another commit also fails; tags are never moved.
- Prerelease tags are not stable baselines. This workflow publishes stable
  `major.minor.patch` versions only.

## Permissions and protection

Test jobs use read-only repository permissions. Only the release job receives
`contents: write` to create the tag and GitHub release. It uses the normal
`GITHUB_TOKEN`; `RELEASE_TOKEN` and a branch-protection bypass are not required.
Keep CodeQL and branch rules enabled.

The previous flow created an unscanned version commit after CI and attempted to
push it to `master`. GitHub rejected that commit with `GH013` because CodeQL had
no results for it. Moving the version change into the reviewed source removes
that extra commit entirely. There is no privileged bot push around the rules.

Tag rules must still permit the release job to create the intended release tags.
If tagging fails, inspect the bounded, credential-redacted rejection details and
verify Actions write permission and tag policy. A tag failure never changes
`master`. Do not weaken branch protection to solve a tag-permission problem.

## Ordering and recovery

Workflow runs serialize per branch without cancellation. If `master` has already
advanced before preparation, the stale run skips publication and lets the newer
run handle the declared version. If it advances during the tag push, the tag can
still be created on the earlier **tested** commit; the release job never retargets
it to newer code and never overwrites the branch.

If tag creation succeeds but its acknowledgment is lost, the job checks the
remote tag before deciding the push failed. A rejected push removes the
local-only candidate tag so a retry cannot mistake it for a published tag.

If GitHub release creation fails after the tag exists, rerun that release job.
It verifies that the remote tag points to its tested source, the manifest agrees,
and the source remains on `master`, then creates the missing release. Repeated
publication is a no-op. Recovering an older release does not mark it latest when
a newer stable tag exists.

## Local validation

```sh
python3 .github/scripts/test_release.py
```

The tests use disposable bare Git remotes and stub GitHub publication. They cover
first releases, explicit versions, unchanged versions, downgrades, protected
branches, rejected tags, stale runs, concurrent updates, lost acknowledgments,
retry recovery, and tag/manifest consistency. They never push to GitHub or publish
a real release. The release job depends on these tests and every matrix result.
