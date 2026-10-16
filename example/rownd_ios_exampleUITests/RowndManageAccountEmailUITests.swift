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

    func testRealHubCustomerCanChangeEmailAndRetainSessionAndCachedProfileAcrossRelaunch() async throws {
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("System custom-scheme dispatch requires iOS 16.4 or newer")
        }
        try await runEmailVerificationScenario(delivery: .systemDispatch, authentication: .realHubOTP)
    }

    func testDelayedHubStartupAuthenticationDoesNotReplaceNativeVerificationSession() async throws {
        guard #available(iOS 16.4, *) else {
            throw XCTSkip("System custom-scheme dispatch requires iOS 16.4 or newer")
        }
        try await runEmailVerificationScenario(
            delivery: .systemDispatch,
            authentication: .realHubOTP,
            race: .delayedHubStartupRefresh
        )
    }

    func testAgedSessionUsesDestinationVerificationThroughSafari() async throws {
        executionTimeAllowance = 900
        try await runSecureEmailChange(minimumAgeSeconds: 605, throughSafari: true)
    }

    func testColdSystemCallbackRetainsReplacementAfterRestart() async throws {
        try await runEmailVerificationScenario(delivery: .systemDispatch, authentication: .realHubOTP, coldCallback: true)
    }

    func testSecureAgedEmailChangeNeedsExistingOTPThenVerifiesAndPersists() async throws {
        executionTimeAllowance = 1000
        try await runSecureEmailChange(minimumAgeSeconds: 605)
    }

    func testSecureFreshEmailChangeVerifiesAndPersists() async throws {
        try await runSecureEmailChange(minimumAgeSeconds: 0)
    }

    func testGoogleLinkedAccountEmailChangePreservesProviderAndCanonicalProfile() async throws {
        try await runSecureEmailChange(minimumAgeSeconds: 0, linkedProvider: "google")
    }

    func testAppleLinkedAccountEmailChangePreservesProviderAndCanonicalProfile() async throws {
        try await runSecureEmailChange(minimumAgeSeconds: 0, linkedProvider: "apple")
    }

    private func runSecureEmailChange(minimumAgeSeconds: Double, throughSafari: Bool = false, linkedProvider: String? = nil) async throws {
        print("SECURE_EMAIL_BACKEND \(backendURL.absoluteString)")
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(
            of: "[0-9]", with: "x", options: .regularExpression
        )
        let originalEmail = "alex-\(suffix.prefix(8))@example.com"
        let destination = "alex-new-\(suffix.prefix(8))@example.com"
        let app = XCUIApplication()
        app.terminate()
        addTeardownBlock { app.terminate() }
        _ = try await request("POST", path: "reset")
        var linkedAccount: [String: Any]?
        if let linkedProvider {
            linkedAccount = try await request("POST", path: "test/multi-login-account", body: ["provider": linkedProvider, "email": originalEmail])
            XCTAssertEqual(linkedAccount?["status"] as? String, "OK")
        }
        app.launchEnvironment = ["ROWND_E2E": "1", "ROWND_E2E_CONFIG_URL": backendURL.appendingPathComponent("config").absoluteString,
                                 "ROWND_E2E_RESET_SESSION": "1"]
        app.launch()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_RESET_SESSION")
        try waitForLabel(app.staticTexts["e2e-sdk-state"], toEqual: "ready")
        try startEmailSignUp(originalEmail, in: app)
        let initialMail = try await waitForPasswordlessCapture(email: originalEmail)
        completeEmailOTP(try XCTUnwrap(initialMail["userInputCode"] as? String), in: app)
        XCTAssertTrue(app.webViews.firstMatch.waitForNonExistence(timeout: 15))
        let handleLabel = app.staticTexts["e2e-session-handle"]
        let s0 = handleLabel.label
        XCTAssertNotEqual(s0, "no-session")
        let initial = try await request("GET", path: "test/email-change-session?handle=\(s0)")
        if let linkedAccount {
            XCTAssertEqual(initial["userId"] as? String, linkedAccount["primaryUserId"] as? String)
            let loginMethods = try XCTUnwrap(initial["loginMethods"] as? [[String: Any]])
            XCTAssertEqual(loginMethods.count, 2)
            XCTAssertTrue(loginMethods.contains { $0["recipeId"] as? String == "passwordless" && $0["email"] as? String == originalEmail })
            XCTAssertTrue(loginMethods.contains {
                $0["thirdPartyId"] as? String == linkedProvider && $0["thirdPartyUserId"] as? String == linkedAccount["providerSubject"] as? String && $0["email"] as? String == originalEmail
            })
        }
        let created = try XCTUnwrap(initial["timeCreated"] as? Double)
        print("SECURE_EMAIL_AGE_START coreCreatedAtMs=\(created) observedAtMs=\(Date().timeIntervalSince1970 * 1000) minimumAgeSeconds=\(minimumAgeSeconds)")
        while true {
            let remaining = minimumAgeSeconds - (Date().timeIntervalSince1970 - created / 1000)
            if remaining <= 0 { break }
            try await Task.sleep(nanoseconds: UInt64(min(remaining, 30) * 1_000_000_000))
            // Keep the simulator automation connection active without refreshing or replacing S0.
            XCTAssertEqual(handleLabel.label, s0)
        }
        let actualAge = Date().timeIntervalSince1970 - created / 1000
        XCTAssertGreaterThanOrEqual(actualAge, minimumAgeSeconds)
        print("SECURE_EMAIL_CORE_AGE_SECONDS \(actualAge)")
        print("SECURE_EMAIL_VIDEO_PHASE edit_destination")

        try openProfile(in: app)
        try replaceText(in: app.webViews.firstMatch.textFields.firstMatch, with: destination)
        app.webViews.firstMatch.buttons["Save edits"].tap()
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Confirm your email change"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.webViews.firstMatch.staticTexts["You are about to change your email address to \(destination). Please confirm this action."].exists)
        let beforeConfirm = try await request("GET", path: "test/email-change-operations")
        XCTAssertEqual((beforeConfirm["operations"] as? [Any])?.count, 0)
        app.webViews.firstMatch.buttons["Continue"].tap()

        var boundSession = s0
        if minimumAgeSeconds > 600 {
            let explanation = app.webViews.firstMatch.staticTexts["Please sign in again to confirm it’s you before changing your email address."]
            XCTAssertTrue(explanation.waitForExistence(timeout: 15))
            let beforeSignIn = try await request("GET", path: "counters")
            XCTAssertEqual(beforeSignIn["verificationEmailDelivered"] as? Int, 0)
            let originalUserId = try XCTUnwrap(initial["userId"] as? String)
            let rejectedState = try await request("GET", path: "test/email-change-user?userId=\(originalUserId)")
            XCTAssertEqual((rejectedState["pending"] as? [Any])?.count, 0)
            XCTAssertTrue((rejectedState["loginMethods"] as? [[String: Any]] ?? []).contains { $0["email"] as? String == originalEmail })
            let rejectedOperations = try await request("GET", path: "test/email-change-operations")
            XCTAssertEqual((rejectedOperations["operations"] as? [[String: Any]])?.first?["statusCode"] as? Int, 403)
            print("SECURE_EMAIL_VIDEO_PHASE freshness_rejected zeroDestinationMail=true zeroPending=true canonicalOriginal=true")
            print("SECURE_EMAIL_VIDEO_PHASE existing_account_sign_in")
            try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "signed-out")
            let login = app.webViews.firstMatch
            XCTAssertTrue(login.textFields.firstMatch.waitForExistence(timeout: 15))
            login.textFields.firstMatch.tap()
            login.textFields.firstMatch.typeText(originalEmail)
            login.buttons["Continue"].tap()
            XCTAssertTrue(login.buttons["Use a code instead"].waitForExistence(timeout: 15))
            let beforeOTP = try await request("GET", path: "counters")
            XCTAssertEqual(beforeOTP["verificationEmailDelivered"] as? Int, 0)
            XCTAssertEqual(beforeOTP["passwordlessConsume"] as? Int, 1)
            let reauthMail = try await waitForPasswordlessCapture(email: originalEmail)
            completeEmailOTP(try XCTUnwrap(reauthMail["userInputCode"] as? String), in: app)
            try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
            try waitForLabel(handleLabel, toDifferFrom: s0)
            boundSession = handleLabel.label
            let sr = try await request("GET", path: "test/email-change-session?handle=\(boundSession)")
            XCTAssertEqual(sr["userId"] as? String, initial["userId"] as? String)
            XCTAssertEqual(sr["tenantId"] as? String, initial["tenantId"] as? String)
            print("SECURE_EMAIL_VIDEO_PHASE automatic_profile_return noDestinationReentry=true sameOwner=true sameTenant=true")
        }

        XCTAssertTrue(app.webViews.firstMatch.staticTexts["Verify your new email"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label == %@", "We have sent a confirmation email to the \(destination) address. Click on the email confirmation link to finalize the process.")).firstMatch.exists)
        print("SECURE_EMAIL_VIDEO_PHASE destination_verification")
        let mail = try await waitForVerificationEmail(email: destination)
        let operationsResponse = try await request("GET", path: "test/email-change-operations")
        let operations = try XCTUnwrap(operationsResponse["operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, minimumAgeSeconds > 600 ? 2 : 1, "One initial PUT and, only when aged, one same-owner retry")
        let updates = operations.filter { $0["action"] as? String == "update" && $0["statusCode"] as? Int == 200 }
        XCTAssertEqual(updates.count, 1)
        XCTAssertTrue(updates.allSatisfy { $0["sessionHandle"] as? String == boundSession })
        if minimumAgeSeconds > 600 {
            XCTAssertEqual(operations.first?["statusCode"] as? Int, 403)
            XCTAssertEqual(operations.first?["sessionHandle"] as? String, s0)
        }
        let waitingCounters = try await request("GET", path: "counters")
        XCTAssertEqual(waitingCounters["verificationEmailDelivered"] as? Int, 1)
        XCTAssertEqual(waitingCounters["passwordlessConsume"] as? Int, minimumAgeSeconds > 600 ? 2 : 1)
        XCTAssertEqual(waitingCounters["createSession"] as? Int, 0)
        try waitForLabel(app.staticTexts["e2e-cached-user-email"], toEqual: originalEmail)
        let pending = try await request("GET", path: "test/email-change-session?handle=\(boundSession)")
        let methods = try XCTUnwrap(pending["loginMethods"] as? [[String: Any]])
        XCTAssertTrue(methods.contains { $0["email"] as? String == originalEmail })
        XCTAssertFalse(methods.contains { $0["email"] as? String == destination })
        let link = try XCTUnwrap(mail["link"] as? String)
        let query = try XCTUnwrap(URLComponents(string: link)).queryItems ?? []
        XCTAssertFalse(query.contains { $0.name == "rowndReauthenticate" })
        XCTAssertTrue(query.contains { $0.name == "rowndPendingVerificationId" && $0.value?.isEmpty == false })
        if throughSafari {
            try openVerificationLinkInSafari(link, app: app)
        } else if #available(iOS 16.4, *) {
            app.open(try XCTUnwrap(URL(string: makeNativeDeepLink(from: link))))
        } else { throw XCTSkip("System URL dispatch requires iOS 16.4") }
        try waitForLabel(handleLabel, toDifferFrom: boundSession)
        let s1 = handleLabel.label
        XCTAssertNotEqual(s1, "no-session")
        try waitForLabel(app.staticTexts["e2e-cached-user-email"], toEqual: destination)
        let verified = try await request("GET", path: "test/email-change-session?handle=\(s1)")
        XCTAssertEqual(verified["userId"] as? String, initial["userId"] as? String)
        XCTAssertEqual(verified["tenantId"] as? String, initial["tenantId"] as? String)
        XCTAssertTrue((verified["loginMethods"] as? [[String: Any]] ?? []).contains {
            $0["email"] as? String == destination && $0["verified"] as? Bool == true
        })
        print("SECURE_EMAIL_VIDEO_PHASE verified_canonical_destination")
        app.terminate()
        print("SECURE_EMAIL_VIDEO_PHASE restart_and_refresh")
        try await setUserProfileGetBehavior(.holdAll)
        app.launch()
        do {
            try await waitForHeldUserProfileGet()
            try waitForLabel(handleLabel, toEqual: s1)
            try waitForLabel(app.staticTexts["e2e-cached-user-email"], toEqual: destination)
        } catch {
            try? await setUserProfileGetBehavior(.normal)
            throw error
        }
        try await setUserProfileGetBehavior(.normal)
        let beforeRefresh = try await request("GET", path: "counters")
        let refresh = app.buttons["Test session refresh"]
        try scrollToElement(refresh, in: app)
        refresh.tap()
        try waitForLabel(app.staticTexts["e2e-scenario-state"], toEqual: "refresh_test_passed")
        let afterRefresh = try await request("GET", path: "counters")
        XCTAssertGreaterThan(afterRefresh["stRefresh"] as? Int ?? 0, beforeRefresh["stRefresh"] as? Int ?? 0)
        try waitForLabel(handleLabel, toEqual: s1)
        try openProfile(in: app)
        try waitForValue(app.webViews.firstMatch.textFields.firstMatch, toEqual: destination)
        var evidence: [String: Any] = ["minimumAgeSeconds": minimumAgeSeconds, "actualAgeSeconds": actualAge,
            "coreCreatedAtMs": created, "initial": initial, "operations": operations, "verified": verified,
            "beforeRefresh": beforeRefresh, "afterRefresh": afterRefresh,
            "canonicalDestinationAfterRestartAndRefresh": true, "noDestinationReentry": true]
        if let linkedAccount, let linkedProvider {
            let fixtureId = try XCTUnwrap(linkedAccount["fixtureId"] as? String)
            let replay = try await request("POST", path: "test/multi-login-provider-replay", body: ["fixtureId": fixtureId])
            XCTAssertEqual(replay["status"] as? String, "OK")
            XCTAssertEqual(replay["provider"] as? String, linkedProvider)
            XCTAssertEqual(replay["primaryUserId"] as? String, initial["userId"] as? String)
            XCTAssertEqual(replay["sessionUserId"] as? String, initial["userId"] as? String)
            XCTAssertEqual(replay["canonicalEmail"] as? String, destination)
            XCTAssertEqual(replay["providerEmail"] as? String, originalEmail)
            XCTAssertEqual(replay["providerSubject"] as? String, linkedAccount["providerSubject"] as? String)
            XCTAssertEqual(replay["providerRecipeUserId"] as? String, linkedAccount["providerRecipeUserId"] as? String)
            let originalMapping = try XCTUnwrap(linkedAccount["mapping"] as? [String: Any])
            let replayMapping = try XCTUnwrap(replay["mapping"] as? [String: Any])
            XCTAssertEqual(originalMapping["status"] as? String, "OK")
            XCTAssertTrue(NSDictionary(dictionary: originalMapping).isEqual(to: replayMapping))
            XCTAssertEqual(replay["passwordlessEmail"] as? String, destination)
            XCTAssertEqual(replay["loginMethodCount"] as? Int, 2)
            XCTAssertEqual(replay["pendingCount"] as? Int, 0)
            evidence["linkedAccountBefore"] = linkedAccount
            evidence["simulatedProviderReplayAfter"] = replay
            print("SECURE_EMAIL_LINKED_ACCOUNT provider=\(linkedProvider) samePrimary=true canonicalDestination=true providerIdentityUnchanged=true providerExchange=simulated")
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "simplified-email-native-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SECURE_EMAIL_VIDEO_PHASE complete")
    }

    private func runEmailVerificationScenario(
        delivery: VerificationLinkDelivery,
        authentication: Authentication = .profileFixture,
        race: EmailVerificationRace = .none,
        minimumAgeSeconds: Double = 0,
        coldCallback: Bool = false
    ) async throws {
        let suffix = UUID().uuidString.lowercased().replacingOccurrences(
            of: "[0-9]",
            with: "x",
            options: .regularExpression
        )
        let initialEmail = "ios-ui-old-\(suffix)@example.com"
        let editedEmail = "ios-ui-new-\(suffix)@example.com"

        let app = XCUIApplication()
        app.terminate()
        addTeardownBlock {
            app.terminate()
            if race == .delayedHubStartupRefresh {
                _ = try? await self.updateStaleRefreshRace(action: "reset")
            }
        }
        _ = try await request("POST", path: "reset")
        app.launchEnvironment = [
            "ROWND_E2E": "1",
            "ROWND_E2E_CONFIG_URL": backendURL.appendingPathComponent("config").absoluteString,
            "ROWND_E2E_RESET_SESSION": "1",
        ]
        if authentication == .profileFixture {
            app.launchEnvironment["ROWND_E2E_EMAIL"] = initialEmail
            app.launchEnvironment["ROWND_E2E_FIRST_NAME"] = "Existing"
        }
        app.launch()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_RESET_SESSION")

        try waitForLabel(app.staticTexts["e2e-sdk-state"], toEqual: "ready")
        try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "signed-out")
        switch authentication {
        case .profileFixture:
            let createSessionButton = app.buttons["e2e-create-session-button"]
            try scrollToElement(createSessionButton, in: app)
            createSessionButton.tap()
            try waitForLabel(app.staticTexts["e2e-scenario-state"], toEqual: "e2e_session_created")
        case .realHubOTP:
            try startEmailSignUp(initialEmail, in: app)
            let capture = try await waitForPasswordlessCapture(email: initialEmail)
            completeEmailOTP(try XCTUnwrap(capture["userInputCode"] as? String), in: app)
            XCTAssertTrue(app.webViews.firstMatch.waitForNonExistence(timeout: 10))
            let counters = try await request("GET", path: "counters")
            XCTAssertEqual(counters["createSession"] as? Int, 0, "Customer lifecycle must not use the profile-session fixture")
            XCTAssertEqual(counters["passwordlessConsume"] as? Int, 1)
        }

        try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
        let initiatingSessionHandle = app.staticTexts["e2e-session-handle"].label
        XCTAssertNotEqual(initiatingSessionHandle, "no-session")
        let initialState = try await request("GET", path: "test/email-change-session?handle=\(initiatingSessionHandle)")
        let createdAt = try XCTUnwrap(initialState["timeCreated"] as? Double)
        let remaining = minimumAgeSeconds - (Date().timeIntervalSince1970 - createdAt / 1000)
        if remaining > 0 {
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        let initiationAge = Date().timeIntervalSince1970 - createdAt / 1000
        XCTAssertGreaterThanOrEqual(initiationAge, minimumAgeSeconds)
        print("DRAFT_EMAIL_INITIATION coreCreatedAt=\(createdAt) ageSeconds=\(initiationAge)")
        XCTAssertTrue(app.staticTexts["e2e-home-screen"].waitForExistence(timeout: 10))

        try openProfile(in: app)
        let webView = app.webViews.firstMatch
        let emailField = webView.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 10))
        try waitForValue(emailField, toEqual: initialEmail)

        try replaceText(in: emailField, with: editedEmail)
        let countersBeforeSave = try await request("GET", path: "counters")
        let saveButton = webView.buttons["Save edits"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        XCTAssertTrue(webView.staticTexts["Confirm your email change"].waitForExistence(timeout: 5))
        XCTAssertFalse(webView.staticTexts["Confirm it’s you"].exists)
        let countersBeforeContinue = try await request("GET", path: "counters")
        for key in ["userUpdate", "userFieldUpdate", "verificationEmailDelivered"] {
            XCTAssertEqual(countersBeforeContinue[key] as? Int, countersBeforeSave[key] as? Int, key)
        }
        webView.buttons["Continue"].tap()

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

        if race == .none {
            XCTAssertTrue(
                webView.staticTexts["Verify your new email"].waitForExistence(timeout: 10)
            )
        }
        let verification = try await waitForVerificationEmail(email: editedEmail)
        let countersAfterContinue = try await request("GET", path: "counters")
        XCTAssertEqual(countersAfterContinue["verificationEmailDelivered"] as? Int,
                       (try XCTUnwrap(countersBeforeSave["verificationEmailDelivered"] as? Int)) + 1)
        let updatesBefore = (countersBeforeSave["userUpdate"] as? Int ?? 0) + (countersBeforeSave["userFieldUpdate"] as? Int ?? 0)
        let updatesAfter = (countersAfterContinue["userUpdate"] as? Int ?? 0) + (countersAfterContinue["userFieldUpdate"] as? Int ?? 0)
        XCTAssertEqual(updatesAfter, updatesBefore + 1)
        for key in ["passwordlessCreate", "passwordlessConsume", "signOut", "stSignOut"] {
            XCTAssertEqual(countersAfterContinue[key] as? Int, countersBeforeSave[key] as? Int, key)
        }
        try waitForLabel(app.staticTexts["e2e-session-handle"], toEqual: initiatingSessionHandle)
        try waitForLabel(app.staticTexts["e2e-cached-user-email"], toEqual: initialEmail)
        let pendingState = try await request("GET", path: "test/email-change-session?handle=\(initiatingSessionHandle)")
        let pending = try XCTUnwrap(pendingState["pending"] as? [[String: Any]])
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?["value"] as? String, editedEmail)
        let methods = try XCTUnwrap(pendingState["loginMethods"] as? [[String: Any]])
        XCTAssertFalse(methods.contains { $0["email"] as? String == editedEmail })
        XCTAssertTrue(methods.contains { $0["email"] as? String == initialEmail })
        let link = try XCTUnwrap(verification["link"] as? String)
        let verificationURL = try XCTUnwrap(URLComponents(string: link))
        let queryItems = Dictionary(uniqueKeysWithValues: (verificationURL.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        let token = try XCTUnwrap(queryItems["token"])
        XCTAssertFalse(token.isEmpty)
        XCTAssertFalse(token.hasPrefix("rownd-pending-email-v1."))
        XCTAssertFalse(queryItems["rowndPendingVerificationId", default: ""].isEmpty)
        XCTAssertNil(queryItems["rowndReauthenticate"])
        XCTAssertEqual(queryItems["apiDomain"], backendURL.absoluteString)
        XCTAssertEqual(queryItems["apiBasePath"], "/auth")
        if race == .delayedHubStartupRefresh {
            let armed = try await updateStaleRefreshRace(action: "arm")
            XCTAssertEqual(armed["armed"] as? Bool, true)
        }
        switch delivery {
        case .directInjection:
            let deepLink = try makeNativeDeepLink(
                from: link,
                expireHubSession: race == .delayedHubStartupRefresh
            )
            app.terminate()
            app.launchEnvironment["ROWND_E2E_DEEP_LINK"] = deepLink
            app.launch()
        case .safari:
            try openVerificationLinkInSafari(link, app: app)
        case .systemDispatch:
            if coldCallback { app.terminate() }
            let deepLink = try XCTUnwrap(URL(string: makeNativeDeepLink(
                from: link,
                expireHubSession: race == .delayedHubStartupRefresh
            )))
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
        let replacementState = try await request("GET", path: "test/email-change-session?handle=\(replacementSessionHandle)")
        XCTAssertEqual(replacementState["userId"] as? String, initialState["userId"] as? String)
        XCTAssertEqual(replacementState["tenantId"] as? String, "public")
        XCTAssertEqual((replacementState["pending"] as? [Any])?.count, 0)
        let replacementMethods = try XCTUnwrap(replacementState["loginMethods"] as? [[String: Any]])
        XCTAssertTrue(replacementMethods.contains { $0["email"] as? String == editedEmail && $0["verified"] as? Bool == true })
        XCTAssertFalse(replacementMethods.contains { $0["email"] as? String == initialEmail })
        let (_, oldSessionResponse) = try await URLSession.shared.data(from: try XCTUnwrap(
            URL(string: "test/email-change-session?handle=\(initiatingSessionHandle)", relativeTo: backendURL)
        ))
        XCTAssertEqual((oldSessionResponse as? HTTPURLResponse)?.statusCode, 404)
        let countersAfterVerification = try await request("GET", path: "counters")
        for key in ["passwordlessCreate", "passwordlessConsume", "signOut", "stSignOut", "verificationEmailDelivered"] {
            XCTAssertEqual(countersAfterVerification[key] as? Int, countersAfterContinue[key] as? Int, key)
        }

        if race == .delayedHubStartupRefresh {
            let heldRace = try await waitForStaleRefreshRace { response in
                let refresh = response["heldRefresh"] as? [String: Any]
                let profile = response["heldProfile"] as? [String: Any]
                return refresh?["lifecycle"] as? String == "held"
                    && response["verificationStatusCode"] as? Int == 200
                    && profile?["lifecycle"] as? String == "held"
            }
            try assertStaleRefreshRace(
                heldRace,
                initiatingSessionHandle: initiatingSessionHandle,
                replacementSessionHandle: replacementSessionHandle
            )
            XCTAssertTrue(webView.exists, "Profile hold must keep the verification WebView open")

            let releasedRace = try await updateStaleRefreshRace(action: "release-stale-refresh")
            try assertRaceEventOrder(
                releasedRace,
                earlier: "replacement-profile-held",
                later: "stale-refresh-released"
            )
            _ = try await waitForStaleRefreshRace { response in
                let refresh = response["heldRefresh"] as? [String: Any]
                return refresh?["lifecycle"] as? String == "released"
                    && refresh?["releaseReason"] as? String == "manual"
                    && refresh?["responseFinished"] as? Bool == true
            }
            let postReleaseRace = try await waitForPostReleaseRefreshOrStableQuietWindow(
                app: app,
                replacementSessionHandle: replacementSessionHandle
            )
            XCTAssertEqual(
                app.staticTexts["e2e-auth-state"].label,
                "authenticated",
                "Stale Hub authentication changed native auth state; race=\(postReleaseRace)"
            )
            XCTAssertEqual(
                sessionHandleLabel.label,
                replacementSessionHandle,
                "Stale Hub authentication replaced S1; race=\(postReleaseRace)"
            )
            let postReleaseRefreshes = try XCTUnwrap(
                postReleaseRace["postReleaseRefreshes"] as? [[String: Any]]
            )
            let postReleaseRefreshAttempts = postReleaseRace["postReleaseRefreshAttempts"] as? Int ?? 0
            if postReleaseRefreshAttempts > 0 {
                XCTAssertEqual(
                    postReleaseRefreshes.count,
                    postReleaseRefreshAttempts,
                    "Every post-release refresh attempt must finish; race=\(postReleaseRace)"
                )
                XCTAssertTrue(
                    postReleaseRefreshes.allSatisfy { $0["statusCode"] as? Int == 401 },
                    "The stale initiating session must be rejected; race=\(postReleaseRace)"
                )
                try assertRaceEventOrder(
                    postReleaseRace,
                    earlier: "refresh-response-finished",
                    later: "post-release-refresh-attempted"
                )
            }
            print("STALE_REFRESH_RACE_POST_RELEASE \(postReleaseRace)")
            _ = try await updateStaleRefreshRace(action: "release-profile")
            let completedRace = try await waitForStaleRefreshRace { response in
                let profile = response["heldProfile"] as? [String: Any]
                return profile?["lifecycle"] as? String == "released"
                    && profile?["releaseReason"] as? String == "manual"
                    && profile?["responseFinished"] as? Bool == true
            }
            let completedProfile = try XCTUnwrap(completedRace["heldProfile"] as? [String: Any])
            XCTAssertEqual(completedProfile["statusCode"] as? Int, 200)
            try assertRaceEventOrder(
                completedRace,
                earlier: "replacement-profile-released",
                later: "replacement-profile-response-finished"
            )
            print("STALE_REFRESH_RACE_PROFILE_FINISHED \(completedRace)")
            try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
            try waitForLabel(sessionHandleLabel, toEqual: replacementSessionHandle)
            let emailExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", editedEmail),
                object: app.staticTexts["e2e-cached-user-email"]
            )
            guard XCTWaiter.wait(for: [emailExpectation], timeout: 15) == .completed else {
                XCTFail("S1 profile response did not preserve edited cached email; race=\(completedRace)")
                return
            }
        } else {
            try waitForLabel(app.staticTexts["e2e-cached-user-email"], toEqual: editedEmail)
        }

        let closeButton = app.webViews.firstMatch.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
        closeButton.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForNonExistence(timeout: 10))
        if authentication == .realHubOTP {
            try resolveAccessToken(in: app)
        }

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "ROWND_E2E_DEEP_LINK")
        try await setUserProfileGetBehavior(.holdAll)
        app.launch()

        do {
            try await waitForHeldUserProfileGet()
            try waitForLabel(app.staticTexts["e2e-sdk-state"], toEqual: "ready")
            try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
            try waitForLabel(sessionHandleLabel, toEqual: replacementSessionHandle)
            if authentication == .realHubOTP {
                try resolveAccessToken(in: app)
            }
            try waitForLabel(app.staticTexts["e2e-cached-user-email"], toEqual: editedEmail)
        } catch {
            try? await setUserProfileGetBehavior(.normal)
            throw error
        }

        try await setUserProfileGetBehavior(.normal)
        if authentication == .realHubOTP {
            let countersBefore = try await request("GET", path: "counters")
            let refresh = app.buttons["Test session refresh"]
            try scrollToElement(refresh, in: app)
            refresh.tap()
            try waitForLabel(app.staticTexts["e2e-scenario-state"], toEqual: "refresh_test_passed")
            let countersAfter = try await request("GET", path: "counters")
            XCTAssertGreaterThan(countersAfter["stRefresh"] as? Int ?? 0, countersBefore["stRefresh"] as? Int ?? 0)
            try waitForLabel(sessionHandleLabel, toEqual: replacementSessionHandle)
        }
        try openProfile(in: app)
        let verifiedEmailField = app.webViews.firstMatch.textFields.firstMatch
        XCTAssertTrue(verifiedEmailField.waitForExistence(timeout: 10))
        try waitForValue(verifiedEmailField, toEqual: editedEmail)
        try waitForLabel(app.staticTexts["e2e-auth-state"], toEqual: "authenticated")
    }

    private func startEmailSignUp(_ email: String, in app: XCUIApplication) throws {
        try waitForLabel(app.staticTexts["e2e-challenge-state"], toEqual: "clear")
        let signUpButton = app.buttons["e2e-sign-up-email-button"]
        try scrollToElement(signUpButton, in: app)
        signUpButton.tap()

        let webView = app.webViews.firstMatch
        let emailField = webView.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(email)
        let continueButton = webView.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
        try waitForLabel(app.staticTexts["e2e-challenge-state"], toEqual: "active")
    }

    private func completeEmailOTP(_ code: String, in app: XCUIApplication) {
        let webView = app.webViews.firstMatch
        let useCodeButton = webView.buttons["Use a code instead"]
        XCTAssertTrue(useCodeButton.waitForExistence(timeout: 10))
        useCodeButton.tap()
        let codeField = webView.textFields.firstMatch
        XCTAssertTrue(codeField.waitForExistence(timeout: 10))
        codeField.tap()
        codeField.typeText(code)
        let continueButton = webView.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10))
        continueButton.tap()
    }

    private func resolveAccessToken(in app: XCUIApplication) throws {
        let button = app.buttons["e2e-resolve-access-token-button"]
        try scrollToElement(button, in: app)
        button.tap()
        try waitForLabel(app.staticTexts["e2e-access-token-resolution"], toEqual: "succeeded")
    }

    private func openVerificationLinkInSafari(_ link: String, app: XCUIApplication) throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        addTeardownBlock { safari.terminate() }
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
        // Safari's first-run menu tip consumes taps outside the popover, including link taps.
        let menuTip = safari.staticTexts["View Bookmarks, Share Menu, and Open Tabs"]
        if menuTip.waitForExistence(timeout: 2) {
            let closeTipButton = safari.buttons["Close"]
            XCTAssertTrue(closeTipButton.waitForExistence(timeout: 2))
            closeTipButton.tap()
            XCTAssertTrue(menuTip.waitForNonExistence(timeout: 2))
        }
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

    private func makeNativeDeepLink(from link: String, expireHubSession: Bool = false) throws -> String {
        let source = try XCTUnwrap(URLComponents(string: link))
        var deepLink = URLComponents()
        deepLink.scheme = "rowndsupertokens"
        deepLink.host = "account"
        deepLink.path = "/verify-email"
        deepLink.queryItems = source.queryItems
        if expireHubSession {
            deepLink.queryItems?.append(URLQueryItem(name: "rowndE2EExpireHubSession", value: "1"))
        }
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
        // isHittable accepts a sliver at the screen edge; tapping it can hit the home indicator.
        let isFullyVisible = {
            element.exists && element.isHittable
                && scrollView.frame.intersection(app.frame).contains(element.frame)
        }
        for _ in 0..<6 {
            if isFullyVisible() {
                return
            }
            scrollView.swipeUp()
        }
        for _ in 0..<6 {
            if isFullyVisible() {
                return
            }
            scrollView.swipeDown()
        }
        guard isFullyVisible() else {
            throw UITestError.elementNotHittable
        }
    }

    private func replaceText(in field: XCUIElement, with text: String) throws {
        for _ in 0..<3 {
            field.tap()
            XCTAssertTrue(XCUIApplication().keyboards.firstMatch.waitForExistence(timeout: 5))
            // Hardware-key shortcuts are unreliable in WKWebView and can stall
            // XCTest's keyboard animation tracking. Use the real editing menu.
            field.press(forDuration: 1)
            let selectAll = XCUIApplication().menuItems["Select All"]
            guard selectAll.waitForExistence(timeout: 2) else { continue }
            selectAll.tap()
            field.typeText(XCUIKeyboardKey.delete.rawValue)
            guard (try? waitForValue(field, toEqual: "", timeout: 5)) != nil else { continue }
            field.typeText(text)
            if (try? waitForValue(field, toEqual: text, timeout: 2)) != nil {
                return
            }
        }
        throw UITestError.timedOutWaitingForElement
    }

    private func textValue(in field: XCUIElement) -> String? {
        guard let value = field.value as? String else { return nil }
        // WebKit exposes the placeholder as the accessibility value of an empty input.
        return value == field.placeholderValue ? "" : value
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
            predicate: NSPredicate { _, _ in self.textValue(in: element) == value },
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

    private func waitForPasswordlessCapture(
        email: String,
        timeout: TimeInterval = 15
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let capture = try await request("GET", path: "test/passwordless/latest")
            if capture["status"] as? String == "OK",
               capture["email"] as? String == email {
                return capture
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw UITestError.passwordlessEmailNotCaptured
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

    private func updateStaleRefreshRace(action: String) async throws -> [String: Any] {
        try await request(
            "POST",
            path: "test/stale-refresh-race",
            body: ["action": action]
        )
    }

    private func waitForStaleRefreshRace(
        timeout: TimeInterval = 20,
        predicate: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = try await request("GET", path: "test/stale-refresh-race")
            if predicate(response) {
                return response
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw UITestError.staleRefreshRaceNotExercised
    }

    private func assertStaleRefreshRace(
        _ response: [String: Any],
        initiatingSessionHandle: String,
        replacementSessionHandle: String
    ) throws {
        let heldRefresh = try XCTUnwrap(response["heldRefresh"] as? [String: Any])
        let heldProfile = try XCTUnwrap(response["heldProfile"] as? [String: Any])
        let events = try XCTUnwrap(response["events"] as? [[String: Any]])
        XCTAssertFalse(
            events.contains {
                let name = $0["name"] as? String ?? ""
                return name.contains("timeout") || name.contains("disconnect")
            },
            "Race harness timed out or disconnected instead of exercising the intended release: \(events)"
        )
        XCTAssertEqual(response["refreshCandidateReserved"] as? Bool, true)
        XCTAssertEqual(heldRefresh["lifecycle"] as? String, "held")
        XCTAssertEqual(heldRefresh["responseFinished"] as? Bool, false)
        XCTAssertEqual(heldProfile["lifecycle"] as? String, "held")
        XCTAssertEqual(heldProfile["responseFinished"] as? Bool, false)
        XCTAssertEqual(heldRefresh["statusCode"] as? Int, 200)
        XCTAssertEqual(
            heldRefresh["sessionHandle"] as? String,
            initiatingSessionHandle,
            "Held startup refresh must belong to initiating session S0"
        )
        XCTAssertEqual(
            heldProfile["requestSessionHandle"] as? String,
            replacementSessionHandle,
            "Held profile request must belong to replacement session S1"
        )
        try assertRaceEventOrder(response, earlier: "refresh-response-held", later: "verification-finished")
        try assertRaceEventOrder(response, earlier: "verification-finished", later: "replacement-profile-held")
    }

    private func waitForPostReleaseRefreshOrStableQuietWindow(
        app: XCUIApplication,
        replacementSessionHandle: String,
        quietWindow: TimeInterval = 3,
        timeout: TimeInterval = 12
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince: Date?
        var latestResponse: [String: Any] = [:]

        while Date() < deadline {
            latestResponse = try await request("GET", path: "test/stale-refresh-race")
            let attempts = latestResponse["postReleaseRefreshAttempts"] as? Int ?? 0
            let finished = latestResponse["postReleaseRefreshes"] as? [[String: Any]] ?? []
            if attempts > 0 && finished.count == attempts {
                return latestResponse
            }

            let remainsStable = app.staticTexts["e2e-auth-state"].label == "authenticated"
                && app.staticTexts["e2e-session-handle"].label == replacementSessionHandle
                && app.webViews.firstMatch.exists
            if remainsStable {
                if stableSince == nil {
                    stableSince = Date()
                }
                if let stableSince, Date().timeIntervalSince(stableSince) >= quietWindow {
                    XCTAssertEqual(attempts, 0, "Quiet path must not hide an unfinished refresh attempt")
                    return latestResponse
                }
            } else {
                stableSince = nil
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTFail("No finished post-release refresh or stable quiet window; race=\(latestResponse)")
        throw UITestError.staleRefreshRaceNotExercised
    }

    private func assertRaceEventOrder(
        _ response: [String: Any],
        earlier: String,
        later: String
    ) throws {
        let events = try XCTUnwrap(response["events"] as? [[String: Any]])
        let earlierOrder = try XCTUnwrap(events.first { $0["name"] as? String == earlier }?["order"] as? Int)
        let laterOrder = try XCTUnwrap(events.first { $0["name"] as? String == later }?["order"] as? Int)
        XCTAssertLessThan(earlierOrder, laterOrder, "Expected \(earlier) before \(later); events=\(events)")
    }

    private func request(
        _ method: String,
        path: String,
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: path, relativeTo: backendURL)))
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

private enum Authentication {
    case profileFixture
    case realHubOTP
}

private enum EmailVerificationRace {
    case none
    case delayedHubStartupRefresh
}

private enum UserProfileGetBehavior: String {
    case holdAll = "hold-all"
    case holdNext = "hold-next"
    case normal
}

private enum UITestError: Error {
    case appDidNotEnterBackground
    case emailVerificationNotCaptured
    case elementNotHittable
    case passwordlessEmailNotCaptured
    case profileDidNotLoad
    case staleRefreshRaceNotExercised
    case timedOutWaitingForElement
    case unexpectedResponse
    case userUpdateNotCaptured
    case userProfileGetNotHeld
    case verificationEmailNotCaptured
}
