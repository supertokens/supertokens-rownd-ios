
# Testing the Rownd SDK

## Running tests

You'll need to first generate mocked classes by running `./gen-mocks.sh`

Then, run the tests by changing the target to `RowndTests` or running individual test suites and functions within their respective files

### Integration and E2E tests

The full E2E suite requires Node.js 18 or newer, Docker, an `iPhone 17` simulator, and a sibling `../supertokens-rownd-hub` checkout. Run `npm install` in both repositories, then run:

```sh
npm run test:e2e
```

This starts the local SuperTokens Core, backend harness, and dynamic Hub server before running the native integration suite, hosted example test, and rendered XCUITests. The UI suite covers real-Hub OTP and magic-link authentication through the WKWebView bridge, restored-session sign-out, relaunch reconciliation of persisted legacy Rownd state against an existing SuperTokens session without remigration, and pending-email verification. The lower-level `test:integration`, `test:e2e:example`, `test:e2e:ui`, and `test:e2e:safari-handoff` scripts require `npm run test:integration:harness` to already be running.

The Safari custom-scheme handoff test runs separately on the simulator because the normal UI suite excludes it:

```sh
npm run test:e2e:safari-handoff:local-plugin
```

The local-plugin commands require a plugin checkout at `../../../supertokens-plugins/packages/rownd-nodejs` with its dependencies installed.

The test opens the generated verification link in Safari, confirms the browser-to-app handoff, and verifies replacement-session adoption and the persisted email. The normal suite also verifies custom-scheme delivery with XCTest system dispatch. The Android browser test similarly verifies Chrome-to-app dispatch separately from native verification and replacement-session adoption.

## Writing tests

We have previously written tests using the XCTesting framework, but have switched to the newer and better [Swift Testing](https://developer.apple.com/documentation/testing/) library. Write new tests using this library.

## Mocking

### Swift Classes

Mock implementation of Swift classes using the [Mockingbird](https://mockingbirdswift.com/) library. See their documentation for more details and checkout examples in Tests/RowndTests/CustomerWebViewManagerTests.swift

If you need to mock a new class, make sure to add `mock(MyClass.self)` to a test suite and then run `./gen-mocks.sh` from the project root directory. This will generate mocked types and store them in the Tests/RowndTests/MockingbirdMocks directory. These generated files are not added to version control.

### Network requests

[Mocker](https://github.com/WeTransfer/Mocker) allows us to mock network requests and responses. See examples in the Tests/RowndTests/AuthTests.swift
