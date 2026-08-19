
# Testing the Rownd SDK

## Running tests

Run the tests by changing the target to `RowndTests` or running individual test suites and functions within their respective files.

### Integration and E2E tests

The full E2E suite requires Node.js 22 or newer, Xcode 26.0.1, Docker, `cloudflared`, and an `iPhone 17` simulator. It uses `https://rownd-hub.supertokens.com` by default and creates a temporary HTTPS tunnel to the local test backend. Run `npm ci`, then run:

```sh
npm run test:e2e
```

Run the same package and unit tests as the PR check with `npm run test:pr`. Run the complete release suite with `npm run test:all`.

Set `IOS_HUB_BASE_URL` to test against a different deployed Hub.

For faster local development, install the sibling Hub dependencies once and run the E2E suite in local-Hub mode:

```sh
npm ci --prefix ../supertokens-rownd-hub
npm run test:e2e:local-hub
```

Local-Hub mode builds and starts `../supertokens-rownd-hub` automatically and does not require `cloudflared`. Set `IOS_LOCAL_HUB_REPO` to use a different checkout path or `E2E_HUB_PORT` to change its port.

This starts the local SuperTokens Core and backend harness before running the native integration suite, hosted example test, and rendered XCUITests against the selected Hub. The UI suite covers Hub OTP and magic-link authentication through the WKWebView bridge, restored-session sign-out, relaunch reconciliation of persisted legacy Rownd state against an existing SuperTokens session without remigration, and pending-email verification. Run UI and Safari tests through `npm run test:e2e`; running their lower-level scripts directly requires an HTTPS tunnel to the integration harness and a matching `IOS_PUBLIC_API_URL`.

The Safari custom-scheme handoff test runs separately on the simulator because the normal UI suite excludes it:

```sh
npm run test:e2e:safari-handoff:local-plugin
```

The local-plugin commands require a plugin checkout at `../../../supertokens-plugins/packages/rownd-nodejs` with its dependencies installed.

The test opens the generated verification link in Safari, confirms the browser-to-app handoff, and verifies replacement-session adoption and the persisted email. The normal suite also verifies custom-scheme delivery with XCTest system dispatch. The Android browser test similarly verifies Chrome-to-app dispatch separately from native verification and replacement-session adoption.

## Writing tests

We have previously written tests using the XCTesting framework, but have switched to the newer and better [Swift Testing](https://developer.apple.com/documentation/testing/) library. Write new tests using this library.

## Mocking network requests

[Mocker](https://github.com/WeTransfer/Mocker) allows us to mock network requests and responses. See examples in the Tests/RowndTests/AuthTests.swift
