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

    func testEditingEmailKeepsVerifiedValueUntilNewEmailIsVerified() async throws {
        let suffix = UUID().uuidString.lowercased()
        let initialEmail = "ios-ui-old-\(suffix)@example.com"
        let editedEmail = "ios-ui-new-\(suffix)@example.com"
        _ = try await request("POST", path: "reset")

        let app = XCUIApplication()
        app.launchEnvironment = [
            "ROWND_E2E": "1",
            "ROWND_E2E_CONFIG_URL": backendURL.appendingPathComponent("config").absoluteString,
            "ROWND_E2E_EMAIL": initialEmail,
            "ROWND_E2E_FIRST_NAME": "Existing",
        ]
        app.launch()

        try waitForLabel(app.staticTexts["e2e-sdk-state"], toEqual: "ready")
        let createSessionButton = app.buttons["e2e-create-session-button"]
        try scrollToElement(createSessionButton, in: app)
        createSessionButton.tap()

        try waitForLabel(app.staticTexts["e2e-scenario-state"], toEqual: "e2e_session_created")
        try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
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
        let token = try XCTUnwrap(verification["token"] as? String)

        app.terminate()
        app.launchEnvironment["ROWND_E2E_VERIFY_EMAIL_TOKEN"] = token
        app.launch()

        try waitForLabel(app.staticTexts["e2e-sdk-state"], toEqual: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
        let verificationRequest = try await waitForCapturedEmailVerification()
        XCTAssertEqual(verificationRequest["statusCode"] as? Int, 200)
        XCTAssertEqual(verificationRequest["authorizationCount"] as? Int, 1)

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_VERIFY_EMAIL_TOKEN")
        app.launch()

        try waitForLabel(app.staticTexts["e2e-sdk-state"], toEqual: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
        try openProfile(in: app)
        let verifiedEmailField = app.webViews.firstMatch.textFields.firstMatch
        XCTAssertTrue(verifiedEmailField.waitForExistence(timeout: 10))
        try waitForValue(verifiedEmailField, toEqual: editedEmail)
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

private enum UITestError: Error {
    case emailVerificationNotCaptured
    case elementNotHittable
    case profileDidNotLoad
    case selectAllNotAvailable
    case timedOutWaitingForElement
    case unexpectedResponse
    case userUpdateNotCaptured
    case verificationEmailNotCaptured
}
