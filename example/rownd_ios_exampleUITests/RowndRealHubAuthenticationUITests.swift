import Foundation
import XCTest

@MainActor
final class RowndRealHubAuthenticationUITests: XCTestCase {
    private let backendURL = URL(
        string: ProcessInfo.processInfo.environment["TEST_BACKEND_URL"] ?? "http://127.0.0.1:3100"
    )!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testEmailOTPFromRealHubEstablishesUsableNativeSessionAndCompletesOnce() async throws {
        let app = try await launchIsolatedApp(resetSession: true)
        let email = "ios-real-hub-otp-\(UUID().uuidString.lowercased())@example.com"

        try startEmailSignIn(email, in: app)
        let capture = try await waitForPasswordlessCapture(email: email)
        let code = try XCTUnwrap(capture["userInputCode"] as? String)

        let webView = app.webViews.firstMatch
        let useCodeButton = webView.buttons["Use a code instead"]
        XCTAssertTrue(useCodeButton.waitForExistence(timeout: 10))
        useCodeButton.tap()
        let codeField = webView.textFields.firstMatch
        XCTAssertTrue(codeField.waitForExistence(timeout: 10))
        codeField.tap()
        codeField.typeText(code)
        webView.buttons["Continue"].tap()

        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-challenge-state"], equalTo: "clear")
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "1")
        XCTAssertNotEqual(app.staticTexts["e2e-session-handle"].label, "no-session")

        let protectedButton = app.buttons["e2e-protected-button"]
        try scrollToElement(protectedButton, in: app)
        protectedButton.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], equalTo: "protected_loaded")
        let counters = try await waitForCounters { ($0["protected"] as? Int) == 1 }
        XCTAssertEqual(counters["passwordlessConsume"] as? Int, 1)
    }

    func testMagicLinkCompletesThroughCustomSchemeAndReplayDoesNotReplaceSession() async throws {
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("System custom-scheme dispatch requires iOS 16.4 or newer")
        }

        let app = try await launchIsolatedApp(resetSession: true)
        let email = "ios-real-hub-link-\(UUID().uuidString.lowercased())@example.com"
        try startEmailSignIn(email, in: app)
        let capture = try await waitForPasswordlessCapture(email: email)
        let capturedLink = try XCTUnwrap(capture["urlWithLinkCode"] as? String)
        let deepLink = try customSchemeURL(from: capturedLink)

        app.open(deepLink)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "1")
        let sessionHandle = app.staticTexts["e2e-session-handle"].label
        XCTAssertNotEqual(sessionHandle, "no-session")
        _ = try await waitForConsumes(count: 1)

        app.open(deepLink)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let replayObservation = try await request("GET", path: "test/passwordless/consumes/settled")
        XCTAssertEqual(replayObservation["count"] as? Int, 1)
        XCTAssertEqual(replayObservation["changedDuringObservation"] as? Bool, false)
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: sessionHandle)
        try waitForLabel(app.staticTexts["e2e-sign-in-completed-count"], equalTo: "1")
        app.terminate()
    }

    func testRestoredSessionCanSignOutFromRealManageAccountAndStaysSignedOut() async throws {
        let app = try await launchIsolatedApp(resetSession: true)
        let createSessionButton = app.buttons["e2e-create-session-button"]
        try scrollToElement(createSessionButton, in: app)
        createSessionButton.tap()
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        let sessionHandle = app.staticTexts["e2e-session-handle"].label
        XCTAssertNotEqual(sessionHandle, "no-session")

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_RESET_SESSION")
        app.launch()
        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "authenticated")
        XCTAssertEqual(app.staticTexts["e2e-session-handle"].label, sessionHandle)

        let manageAccountButton = app.buttons["e2e-manage-account-button"]
        try scrollToElement(manageAccountButton, in: app)
        manageAccountButton.tap()
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.staticTexts["Your profile"].waitForExistence(timeout: 15))
        let signOutButton = webView.buttons["Sign out"].firstMatch
        XCTAssertTrue(signOutButton.waitForExistence(timeout: 10))
        let signOutCountBefore = (try await request("GET", path: "counters"))["stSignOut"] as? Int ?? 0
        signOutButton.tap()

        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "signed-out")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: "no-session")
        _ = try await waitForCounters { ($0["stSignOut"] as? Int ?? 0) > signOutCountBefore }

        app.terminate()
        app.launch()
        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "signed-out")
        try waitForLabel(app.staticTexts["e2e-session-handle"], equalTo: "no-session")
    }

    private func launchIsolatedApp(resetSession: Bool) async throws -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        addTeardownBlock { app.terminate() }
        _ = try await request("POST", path: "reset")
        app.launchEnvironment = [
            "ROWND_E2E": "1",
            "ROWND_E2E_CONFIG_URL": backendURL.appendingPathComponent("config").absoluteString,
        ]
        if resetSession {
            app.launchEnvironment["ROWND_E2E_RESET_SESSION"] = "1"
        }
        app.launch()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_RESET_SESSION")
        try waitForLabel(app.staticTexts["e2e-sdk-state"], equalTo: "ready")
        if resetSession {
            try waitForLabel(app.staticTexts["e2e-auth-state"], equalTo: "signed-out")
        }
        return app
    }

    private func startEmailSignIn(_ email: String, in app: XCUIApplication) throws {
        try waitForLabel(app.staticTexts["e2e-challenge-state"], equalTo: "clear")
        let signInButton = app.buttons["e2e-sign-in-email-button"]
        try scrollToElement(signInButton, in: app)
        signInButton.tap()

        let webView = app.webViews.firstMatch
        let emailField = webView.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email)
        try waitForLabel(app.staticTexts["e2e-challenge-state"], equalTo: "clear")
        let continueButton = webView.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        try waitForLabel(app.staticTexts["e2e-challenge-state"], equalTo: "active")
    }

    private func customSchemeURL(from link: String) throws -> URL {
        let source = try XCTUnwrap(URLComponents(string: link))
        var deepLink = URLComponents()
        deepLink.scheme = "rowndsupertokens"
        deepLink.host = "account"
        deepLink.path = "/login"
        deepLink.queryItems = source.queryItems
        deepLink.fragment = source.fragment
        return try XCTUnwrap(deepLink.url)
    }

    private func scrollToElement(_ element: XCUIElement, in app: XCUIApplication) throws {
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<8 {
            if element.exists,
               element.isHittable,
               element.frame.minY >= app.frame.minY,
               element.frame.maxY <= app.frame.maxY - 20 {
                return
            }
            if element.exists && element.frame.minY < app.frame.minY {
                scrollView.swipeDown()
            } else {
                scrollView.swipeUp()
            }
        }
        guard element.exists && element.isHittable else { throw RealHubUITestError.elementNotHittable }
    }

    private func waitForLabel(
        _ element: XCUIElement,
        equalTo label: String,
        timeout: TimeInterval = 20
    ) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", label),
            object: element
        )
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            throw RealHubUITestError.timedOut
        }
    }

    private func waitForPasswordlessCapture(email: String) async throws -> [String: Any] {
        try await poll(path: "test/passwordless/latest") {
            $0["status"] as? String == "OK" && $0["email"] as? String == email
        }
    }

    private func waitForConsumes(count: Int) async throws -> [String: Any] {
        try await poll(path: "test/passwordless/consumes") { ($0["count"] as? Int ?? 0) >= count }
    }

    private func waitForCounters(
        predicate: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        try await poll(path: "counters", predicate: predicate)
    }

    private func poll(
        path: String,
        timeout: TimeInterval = 15,
        predicate: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await request("GET", path: path)
            if predicate(response) { return response }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw RealHubUITestError.timedOut
    }

    private func request(_ method: String, path: String) async throws -> [String: Any] {
        var request = URLRequest(url: backendURL.appendingPathComponent(path))
        request.httpMethod = method
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RealHubUITestError.unexpectedResponse
        }
        return payload
    }
}

private enum RealHubUITestError: Error {
    case elementNotHittable
    case timedOut
    case unexpectedResponse
}
