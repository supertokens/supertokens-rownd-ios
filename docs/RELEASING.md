# Releasing Rownd for iOS

## Setup

Add these GitHub Actions repository secrets:

- `COCOAPODS_TRUNK_TOKEN`: CocoaPods Trunk publishing token.
- `ROWND_HUB_TOKEN`: Fine-grained GitHub token with read-only Contents access to the private `supertokens-rownd-hub` repository.

The release workflow uses the built-in `GITHUB_TOKEN` to create the release commit, tag, and GitHub release.

## Release

Every push to `main` starts `.github/workflows/release.yml`. The workflow runs package, unit, and full E2E tests before releasing. Conventional commits determine whether a release is needed and whether the next version is a major, minor, or patch release.

The workflow can also be started manually from the Actions tab on `main`. Enable **Skip E2E tests for this release** to run the package and unit tests but bypass E2E tests. Manual releases from other branches are not allowed.

The workflow bumps `VERSION`, `Sources/Rownd/framework/Version.swift`, and `RowndSupertokens.podspec`, validates the podspec, creates a release commit and `vX.Y.Z` tag, creates the GitHub release, and publishes `RowndSupertokens` to CocoaPods.

Before releasing, the workflow verifies that `VERSION` matches the latest tag and that the tag belongs to the `main` branch history. This prevents stale branches from recreating an existing version.

The existing `v0.1.9` and `v0.1.10` release commits must be merged into `main` before enabling the workflow. Do not recreate or move those published tags.

If CocoaPods validation fails with a missing `libarclite` error on Xcode 15 or newer, install the missing `libarclite` files or release from an Xcode environment that still includes them. Some transitive CocoaPods dependencies still declare old iOS deployment targets, which triggers this toolchain issue during validation.

## Verify

After release, confirm CocoaPods can see the published pod:

```sh
pod trunk info RowndSupertokens
```

If CocoaPods publication fails after the GitHub release is created, inspect the release workflow logs, fix the publication issue, and publish the tagged podspec manually. Do not recreate or move an existing release tag.
