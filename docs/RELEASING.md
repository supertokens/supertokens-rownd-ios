# Releasing Rownd for iOS

## Setup

Set `GITHUB_TOKEN` to a GitHub Personal Access Token with repository permissions.

Authenticate with CocoaPods trunk before publishing:

```sh
pod trunk register <email> "SuperTokens" --description="SuperTokens release machine"
```

## Release

From a clean checkout of the latest `main` branch:

1. Run `npm install` if dependencies are missing.
2. Run `npm run release` and confirm the prompts.

The release command bumps `VERSION`, `Sources/Rownd/framework/Version.swift`, and `Rownd.podspec`, creates a GitHub release with a `vX.Y.Z` tag, validates the podspec, and publishes `Rownd` to CocoaPods.

If CocoaPods validation fails with a missing `libarclite` error on Xcode 15 or newer, install the missing `libarclite` files or release from an Xcode environment that still includes them. Some transitive CocoaPods dependencies still declare old iOS deployment targets, which triggers this toolchain issue during validation.

## Verify

After release, confirm CocoaPods can see the published pod:

```sh
pod trunk info Rownd
```
