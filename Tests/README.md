
# Testing the Rownd SDK

## Running tests

You'll need to first generate mocked classes by running `./gen-mocks.sh`

Then, run the tests by changing the target to `RowndTests` or running individual test suites and functions within their respective files

### Integration and E2E tests

The full E2E suite requires Docker, an `iPhone 17` simulator, and a sibling `../supertokens-rownd-hub` checkout. Run `npm install` in both repositories, then run:

```sh
npm run test:e2e
```

This starts the local SuperTokens Core, backend harness, and dynamic Hub server before running the native integration suite, hosted example test, and rendered manage-account XCUITest. The lower-level `test:integration`, `test:e2e:example`, and `test:e2e:ui` scripts require `npm run test:integration:harness` to already be running.

## Writing tests

We have previously written tests using the XCTesting framework, but have switched to the newer and better [Swift Testing](https://developer.apple.com/documentation/testing/) library. Write new tests using this library.

## Mocking

### Swift Classes

Mock implementation of Swift classes using the [Mockingbird](https://mockingbirdswift.com/) library. See their documentation for more details and checkout examples in Tests/RowndTests/CustomerWebViewManagerTests.swift

If you need to mock a new class, make sure to add `mock(MyClass.self)` to a test suite and then run `./gen-mocks.sh` from the project root directory. This will generate mocked types and store them in the Tests/RowndTests/MockingbirdMocks directory. These generated files are not added to version control.

### Network requests

[Mocker](https://github.com/WeTransfer/Mocker) allows us to mock network requests and responses. See examples in the Tests/RowndTests/AuthTests.swift
