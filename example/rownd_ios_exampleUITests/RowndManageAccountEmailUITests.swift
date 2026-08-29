import Foundation
import XCTest

@MainActor
final class RowndManageAccountEmailUITests: XCTestCase {
    private let backendURL = URL(
        string: ProcessInfo.processInfo.environment["TEST_BACKEND_URL"] ?? "http://127.0.0.1:3100"
    )!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testEditingEmailKeepsVerifiedValueAndCanCloseWebViewAfterVerification() async throws {
        try await runEmailVerificationScenario(delivery: .directInjection)
    }

    func testEditingEmailThroughSafariOpensAppAndPersistsVerifiedProfile() async throws {
        try await runEmailVerificationScenario(delivery: .safari)
    }

    func testSystemDispatchOpensAppAndPersistsVerifiedProfile() async throws {
        try await runEmailVerificationScenario(delivery: .systemDispatch)
    }

    private func runEmailVerificationScenario(delivery: VerificationLinkDelivery) async throws {
        let suffix = UUID().uuidString.lowercased()
        let initialEmail = "ios-ui-old-\(suffix)@example.com"
        let editedEmail = "ios-ui-new-\(suffix)@example.com"

        let app = XCUIApplication()
        app.terminate()
        addTeardownBlock { app.terminate() }
        _ = try await request("POST", path: "reset")
        app.launchEnvironment = [
            "ROWND_E2E": "1",
            "ROWND_E2E_CONFIG_URL": backendURL.appendingPathComponent("config").absoluteString,
            "ROWND_E2E_EMAIL": initialEmail,
            "ROWND_E2E_FIRST_NAME": "Existing",
            "ROWND_E2E_RESET_SESSION": "1",
        ]
        app.launch()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_RESET_SESSION")

        try waitForLabel(app.staticTexts["e2e-sdk-state"], toEqual: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "signed-out")
        let createSessionButton = app.buttons["e2e-create-session-button"]
        try scrollToElement(createSessionButton, in: app)
        createSessionButton.tap()

        try waitForLabel(app.staticTexts["e2e-scenario-state"], toEqual: "e2e_session_created")
        try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
        let initiatingSessionHandle = app.staticTexts["e2e-session-handle"].label
        XCTAssertNotEqual(initiatingSessionHandle, "no-session")
        XCTAssertTrue(app.staticTexts["e2e-home-screen"].waitForExistence(timeout: 10))

        try openProfile(in: app)
        let webView = app.webViews.firstMatch
        let emailField = webView.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 10))
        try waitForValue(emailField, toEqual: initialEmail)

        try replaceText(in: emailField, with: editedEmail, app: app)
        try waitForValue(emailField, toEqual: editedEmail)
        let saveButton = webView.buttons["Save edits"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        let updateRequest = try await waitForCapturedUserUpdate()
        XCTAssertEqual(updateRequest["statusCode"] as? Int, 200)
        let body = try XCTUnwrap(updateRequest["body"] as? [String: Any])
        if updateRequest["field"] as? String == "email" {
            XCTAssertEqual(body["value"] as? String, editedEmail)
        } else {
            let data = try XCTUnwrap(body["data"] as? [String: Any])
            XCTAssertEqual(data.count, 1)
            XCTAssertEqual(data["email"] as? String, editedEmail)
        }

        try waitForValue(emailField, toEqual: initialEmail)
        let verification = try await waitForVerificationEmail(email: editedEmail)
        let link = try XCTUnwrap(verification["link"] as? String)
        let verificationURL = try XCTUnwrap(URLComponents(string: link))
        let queryItems = Dictionary(uniqueKeysWithValues: (verificationURL.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        let token = try XCTUnwrap(queryItems["token"])
        XCTAssertFalse(token.isEmpty)
        XCTAssertFalse(token.hasPrefix("rownd-pending-email-v1."))
        XCTAssertFalse(queryItems["rowndPendingVerificationId", default: ""].isEmpty)
        XCTAssertEqual(queryItems["apiDomain"], backendURL.absoluteString)
        XCTAssertEqual(queryItems["apiBasePath"], "/auth")
        switch delivery {
        case .directInjection:
            let deepLink = try makeNativeDeepLink(from: link)
            app.terminate()
            app.launchEnvironment["ROWND_E2E_DEEP_LINK"] = deepLink
            app.launch()
        case .safari:
            try openVerificationLinkInSafari(link, app: app)
        case .systemDispatch:
            let deepLink = try XCTUnwrap(URL(string: makeNativeDeepLink(from: link)))
            app.terminate()
            if #available(iOS 16.4, *) {
                app.open(deepLink)
            } else {
                throw XCTSkip("System URL dispatch requires iOS 16.4 or newer")
            }
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Custom URL scheme did not dispatch to the app")
        }

        try waitForLabel(app.staticTexts["e2e-sdk-state"], toEqual: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
        let verificationRequest = try await waitForCapturedEmailVerification()
        XCTAssertEqual(verificationRequest["statusCode"] as? Int, 200)
        XCTAssertEqual(verificationRequest["authorizationCount"] as? Int, 1)
        XCTAssertEqual(
            verificationRequest["pendingVerificationId"] as? String,
            queryItems["rowndPendingVerificationId"]
        )
        let responseSessionHeaders = try XCTUnwrap(
            verificationRequest["responseSessionHeaders"] as? [String: Bool]
        )
        XCTAssertEqual(responseSessionHeaders["accessToken"], true)
        XCTAssertEqual(responseSessionHeaders["refreshToken"], true)
        XCTAssertEqual(responseSessionHeaders["frontToken"], true)
        let sessionHandleLabel = app.staticTexts["e2e-session-handle"]
        try waitForLabel(sessionHandleLabel, toDifferFrom: initiatingSessionHandle)
        let replacementSessionHandle = sessionHandleLabel.label
        XCTAssertNotEqual(replacementSessionHandle, "no-session")
        try waitForLabel(app.staticTexts["e2e-cached-user-email"], toEqual: editedEmail)

        let closeButton = app.webViews.firstMatch.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
        closeButton.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForNonExistence(timeout: 10))

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_DEEP_LINK")
        try await setUserProfileGetBehavior(.holdNext)
        app.launch()

        do {
            try await waitForHeldUserProfileGet()
            try waitForLabel(app.staticTexts["e2e-sdk-state"], toEqual: "ready")
            try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
            try waitForLabel(sessionHandleLabel, toEqual: replacementSessionHandle)
            try waitForLabel(app.staticTexts["e2e-cached-user-email"], toEqual: editedEmail)
        } catch {
            try? await setUserProfileGetBehavior(.normal)
            throw error
        }

        try await setUserProfileGetBehavior(.normal)
        try openProfile(in: app)
        let verifiedEmailField = app.webViews.firstMatch.textFields.firstMatch
        XCTAssertTrue(verifiedEmailField.waitForExistence(timeout: 10))
        try waitForValue(verifiedEmailField, toEqual: editedEmail)
    }

    private func openVerificationLinkInSafari(_ link: String, app: XCUIApplication) throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()

        let addressField = safari.textFields["Address"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 10))
        addressField.tap()
        addressField.press(forDuration: 1)
        let selectAll = safari.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap()
        }
        addressField.typeText(link)
        safari.keyboards.buttons["Go"].tap()

        let verificationLink = safari.links["Open in app"]
        XCTAssertTrue(verificationLink.waitForExistence(timeout: 10))
        try assertBackgrounded(app)
        verificationLink.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let safariOpenButton = safari.buttons["Open"]
        let springboardOpenButton = springboard.buttons["Open"]
        if safariOpenButton.waitForExistence(timeout: 5) {
            safariOpenButton.tap()
        } else {
            XCTAssertTrue(springboardOpenButton.waitForExistence(timeout: 5), "Safari confirmation did not appear")
            springboardOpenButton.tap()
        }

        XCTAssertTrue(
            app.wait(for: .runningForeground, timeout: 10),
            "Safari did not dispatch the custom URL scheme to the app"
        )
    }

    private func assertBackgrounded(_ app: XCUIApplication) throws {
        let appWasBackgrounded = app.wait(for: .runningBackground, timeout: 2)
            || app.wait(for: .runningBackgroundSuspended, timeout: 2)
        guard appWasBackgrounded else {
            throw UITestError.appDidNotEnterBackground
        }
    }

    private func makeNativeDeepLink(from link: String) throws -> String {
        let source = try XCTUnwrap(URLComponents(string: link))
        var deepLink = URLComponents()
        deepLink.scheme = "rowndsupertokens"
        deepLink.host = "account"
        deepLink.path = "/verify-email"
        deepLink.queryItems = source.queryItems
        deepLink.fragment = source.fragment
        return try XCTUnwrap(deepLink.url?.absoluteString)
    }

    private func openProfile(in app: XCUIApplication) throws {
        let profileButton = app.buttons["e2e-manage-account-button"]
        try scrollToElement(profileButton, in: app)
        profileButton.tap()

        let title = app.webViews.firstMatch.staticTexts["Your profile"]
        guard title.waitForExistence(timeout: 15) else {
            throw UITestError.profileDidNotLoad
        }
    }

    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) throws {
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<6 {
            if element.exists && element.isHittable {
                return
            }
            scrollView.swipeUp()
        }
        for _ in 0..<6 {
            if element.exists && element.isHittable {
                return
            }
            scrollView.swipeDown()
        }
        guard element.exists && element.isHittable else {
            throw UITestError.elementNotHittable
        }
    }

    private func replaceText(in field: XCUIElement, with text: String, app: XCUIApplication) throws {
        field.tap()
        field.press(forDuration: 1)

        let selectAll = app.menuItems["Select All"]
        guard selectAll.waitForExistence(timeout: 2) else {
            throw UITestError.selectAllNotAvailable
        }
        selectAll.tap()
        field.typeText(text)
    }

    private func waitForLabel(
        _ element: XCUIElement,
        toEqual label: String,
        timeout: TimeInterval = 15
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw UITestError.timedOutWaitingForElement
        }
    }

    private func waitForLabel(
        _ element: XCUIElement,
        toDifferFrom label: String,
        timeout: TimeInterval = 15
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label != %@ AND label != %@", label, "no-session"),
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw UITestError.timedOutWaitingForElement
        }
    }

    private func waitForValue(
        _ element: XCUIElement,
        toEqual value: String,
        timeout: TimeInterval = 10
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw UITestError.timedOutWaitingForElement
        }
    }

    private func waitForCapturedUserUpdate(timeout: TimeInterval = 10) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let requests = try await request("GET", path: "captured-requests")
            if let update = requests["userUpdate"] as? [String: Any], update["statusCode"] != nil {
                return update
            }
            if let update = requests["userFieldUpdate"] as? [String: Any], update["statusCode"] != nil {
                return update
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw UITestError.userUpdateNotCaptured
    }

    private func waitForCapturedEmailVerification(timeout: TimeInterval = 10) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let requests = try await request("GET", path: "captured-requests")
            if let verification = requests["emailVerify"] as? [String: Any], verification["statusCode"] != nil {
                return verification
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw UITestError.emailVerificationNotCaptured
    }

    private func waitForVerificationEmail(
        email: String,
        timeout: TimeInterval = 10
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let verification = try await request("GET", path: "test/email-verification/latest")
            if verification["status"] as? String == "OK",
               verification["email"] as? String == email {
                return verification
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw UITestError.verificationEmailNotCaptured
    }

    private func setUserProfileGetBehavior(_ behavior: UserProfileGetBehavior) async throws {
        let response = try await request(
            "POST",
            path: "test/user-get-behavior",
            body: ["behavior": behavior.rawValue]
        )
        guard response["behavior"] as? String == behavior.rawValue else {
            throw UITestError.unexpectedResponse
        }
    }

    private func waitForHeldUserProfileGet(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await request("GET", path: "test/user-get-behavior")
            if response["behavior"] as? String == "holding",
               response["heldRequestCount"] as? Int == 1 {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw UITestError.userProfileGetNotHeld
    }

    private func request(
        _ method: String,
        path: String,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: backendURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw UITestError.unexpectedResponse
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private enum VerificationLinkDelivery {
    case directInjection
    case safari
    case systemDispatch
}

private enum UserProfileGetBehavior: String {
    case holdNext = "hold-next"
    case normal
}

private enum UITestError: Error {
    case appDidNotEnterBackground
    case emailVerificationNotCaptured
    case elementNotHittable
    case profileDidNotLoad
    case selectAllNotAvailable
    case timedOutWaitingForElement
    case unexpectedResponse
    case userUpdateNotCaptured
    case userProfileGetNotHeld
    case verificationEmailNotCaptured
}
