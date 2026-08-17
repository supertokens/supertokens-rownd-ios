import Foundation
import Testing
import AnyCodable

@testable import Rownd

@Suite(.serialized) struct SuperTokensSessionIntegrationTests {
    @Test func pluginAppConfigRouteIsServedBySuperTokensHarness() async throws {
        try await TestInfrastructure.prepare()

        let appConfig = try await getJSON(path: "auth/plugin/rownd/app-config")
        let app = try #require(appConfig["app"] as? [String: Any])

        #expect(appConfig["status"] as? String == "OK")
        #expect(app["id"] as? String == "app_test_rownd_ios")
        #expect(app["name"] as? String == "Rownd iOS Integration Tests")
    }

    @Test func urlProtocolCapturesSessionHeadersFromSuperTokensResponse() async throws {
        try await TestInfrastructure.prepare()

        _ = try await createHarnessSession(userId: "ios-session-capture-user")

        #expect(await SuperTokensSessionBridge.doesSessionExist())
        let accessToken = try #require(await SuperTokensSessionBridge.getAccessToken())
        #expect(!accessToken.isEmpty)
    }

    @Test func capturedSessionCanCallProtectedRouteAndSignOut() async throws {
        try await TestInfrastructure.prepare()

        let userId = try await createHarnessSession(userId: "ios-protected-user")

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["status"] as? String == "OK")
        #expect(protected["userId"] as? String == userId)

        await SuperTokensSessionBridge.signOut()

        #expect(await !SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
    }

    @Test func signOutAllCallsPluginSignoutAndClearsLocalSession() async throws {
        try await TestInfrastructure.prepare()

        _ = try await createHarnessSession(userId: "ios-signout-all-user")
        #expect(await SuperTokensSessionBridge.doesSessionExist())

        try await Rownd.signOut(scope: .all)

        for _ in 0..<40 {
            if await !SuperTokensSessionBridge.doesSessionExist() {
                break
            }

            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(await !SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == nil)

        let counters = try await getJSON(path: "counters")
        #expect(counters["signOut"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)

        let capturedRequests = try await getJSON(path: "captured-requests")
        let signOutRequest = try #require(capturedRequests["signOut"] as? [String: Any])
        let authorization = try #require(signOutRequest["authorization"] as? String)
        #expect(authorization.hasPrefix("Bearer "))
        #expect(signOutRequest["authorizationCount"] as? Int == 1)
        #expect(signOutRequest["rowndAppKey"] as? String == nil)
    }

    @Test func protectedPluginRouteRefreshesSuperTokensSessionWithoutLegacyRefresh() async throws {
        try await TestInfrastructure.prepare()

        let userId = try await createHarnessSession(userId: "ios-refresh-user")

        let response = try await getJSON(path: "test/refresh-once")
        #expect(response["status"] as? String == "OK")
        #expect(response["userId"] as? String == userId)

        let counters = try await getJSON(path: "counters")
        #expect(counters["refreshOnce"] as? Int == 2)
        #expect(counters["stRefresh"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)

        let capturedRequests = try await getJSON(path: "captured-requests")
        let refreshOnceRequest = try #require(capturedRequests["refreshOnce"] as? [String: Any])
        let authorization = try #require(refreshOnceRequest["authorization"] as? String)
        #expect(authorization.hasPrefix("Bearer "))
        #expect(refreshOnceRequest["authorizationCount"] as? Int == 1)
        #expect(refreshOnceRequest["rowndAppKey"] as? String == nil)
    }

    @Test func hubStyleAuthenticationPayloadBootstrapsNativeSession() async throws {
        try await TestInfrastructure.prepare()

        let session = try await createHarnessSessionResponse(userId: "ios-hub-bootstrap-user", captureLocally: false)
        let accessToken = try #require(header(session.response, named: "st-access-token"))

        clearLocalSuperTokensSessionArtifacts()
        #expect(await !SuperTokensSessionBridge.doesSessionExist())

        await Task.detached(priority: .userInitiated) {
            _ = SuperTokensSessionBridge.bootstrapSession(
                accessToken: accessToken,
                refreshToken: header(session.response, named: "st-refresh-token"),
                frontToken: header(session.response, named: "front-token"),
                antiCSRF: header(session.response, named: "anti-csrf")
            )
        }.value
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()

        #expect(await SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["status"] as? String == "OK")
        #expect(protected["userId"] as? String == session.userId)

        let counters = try await getJSON(path: "counters")
        #expect(counters["legacyRefresh"] as? Int == 0)
        #expect(counters["migrate"] as? Int == 0)

        let capturedRequests = try await getJSON(path: "captured-requests")
        let protectedRequest = try #require(capturedRequests["protected"] as? [String: Any])
        #expect(protectedRequest["authorizationCount"] as? Int == 1)
        #expect(protectedRequest["rowndAppKey"] as? String == nil)
    }

    @Test func interceptedLegacyMigrationSynchronizesCompatibilityAuthState() async throws {
        try await TestInfrastructure.prepare()

        let legacyAccessToken = generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970)
        try await migrateLegacySession(
            accessToken: legacyAccessToken,
            refreshToken: "legacy-refresh-token"
        )

        #expect(await SuperTokensSessionBridge.doesSessionExist())
        let migratedAccessToken = try #require(await SuperTokensSessionBridge.getAccessToken())
        #expect(migratedAccessToken != legacyAccessToken)
        // Assert the launch-time state directly; Rownd.getAccessToken can repair it and mask this regression.
        #expect(await currentAuthAccessToken() == migratedAccessToken)
        #expect(await currentAuthRefreshToken() == nil)

        let counters = try await getJSON(path: "counters")
        #expect(counters["migrate"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["status"] as? String == "OK")
        #expect(protected["userId"] as? String == "ios-test-user")
    }

    @Test func getAccessTokenWaitsForInFlightLegacyMigration() async throws {
        try await TestInfrastructure.prepare()

        let legacyAccessToken = generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970)
        let persistedLegacyAuthState = AuthState(
            accessToken: legacyAccessToken,
            refreshToken: "legacy-refresh-token"
        )
        await MainActor.run {
            Context.currentContext.store.dispatch(SetAuthState(payload: persistedLegacyAuthState))
        }
        #expect(await !SuperTokensSessionBridge.doesSessionExist())

        let migrationStarted = AsyncTestSignal()
        let releaseMigration = AsyncTestSignal()
        let accessTokenReadStarted = AsyncTestSignal()
        let accessTokenReadCount = AsyncTestCounter()
        let originalAuthenticator = Context.currentContext.authenticator
        Context.currentContext.authenticator = Authenticator(
            sessionBridge: SuperTokensSessionBridgeClient(
                doesSessionExist: SuperTokensSessionBridge.doesSessionExist,
                getAccessToken: {
                    let accessToken = await SuperTokensSessionBridge.getAccessToken()
                    await accessTokenReadCount.increment()
                    if accessToken == nil {
                        await accessTokenReadStarted.signal()
                    }
                    return accessToken
                },
                attemptRefresh: SuperTokensSessionBridge.attemptRefresh
            )
        )
        defer { Context.currentContext.authenticator = originalAuthenticator }

        let liveClient = LegacySessionMigrationClient(
            apiDomain: TestInfrastructure.supertokensConfig.apiDomain,
            apiBasePath: TestInfrastructure.supertokensConfig.apiBasePath,
            legacyApiDomain: TestInfrastructure.supertokensConfig.apiDomain
        )
        let delayedClient = LegacySessionMigrationClient(migrateHandler: { accessToken in
            await migrationStarted.signal()
            await releaseMigration.wait()
            return try await liveClient.migrate(legacyAccessToken: accessToken)
        })

        let migrationTask = Task {
            await LegacySessionMigrator.migrateIfNeeded(
                authState: persistedLegacyAuthState,
                dependencies: LegacySessionMigrationDependencies(client: delayedClient)
            )
        }
        await migrationStarted.wait()

        let accessTokenTask = Task {
            return try await Rownd.getAccessToken()
        }
        await accessTokenReadStarted.wait()
        await releaseMigration.signal()

        let accessToken: String?
        do {
            accessToken = try await accessTokenTask.value
        } catch {
            await migrationTask.value
            throw error
        }
        await migrationTask.value

        let migratedAccessToken = try #require(await SuperTokensSessionBridge.getAccessToken())
        #expect(migratedAccessToken != legacyAccessToken)
        #expect(accessToken == migratedAccessToken)
        #expect(await accessTokenReadCount.value == 2)
    }

    @Test func signOutCancelsInFlightLegacyMigration() async throws {
        try await TestInfrastructure.prepare()

        let legacyAuthState = AuthState(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: "legacy-refresh-token"
        )
        await MainActor.run {
            Context.currentContext.store.dispatch(SetAuthState(payload: legacyAuthState))
        }

        let migrationStarted = AsyncTestSignal()
        let releaseMigration = AsyncTestSignal()
        let cancellationObserved = AsyncTestSignal()
        let liveClient = LegacySessionMigrationClient(
            apiDomain: TestInfrastructure.supertokensConfig.apiDomain,
            apiBasePath: TestInfrastructure.supertokensConfig.apiBasePath,
            legacyApiDomain: TestInfrastructure.supertokensConfig.apiDomain
        )
        let delayedClient = LegacySessionMigrationClient(migrateHandler: { accessToken in
            await migrationStarted.signal()
            return try await withTaskCancellationHandler {
                await releaseMigration.wait()
                return try await liveClient.migrate(legacyAccessToken: accessToken)
            } onCancel: {
                Task { await cancellationObserved.signal() }
            }
        })

        let migrationTask = Task {
            await LegacySessionMigrator.migrateIfNeeded(
                authState: legacyAuthState,
                dependencies: LegacySessionMigrationDependencies(client: delayedClient)
            )
        }
        await migrationStarted.wait()

        let signOutTask = Task { await Rownd.signOut() }
        await cancellationObserved.wait()
        await releaseMigration.signal()
        await migrationTask.value
        await signOutTask.value

        #expect(await !SuperTokensSessionBridge.doesSessionExist())
        #expect(await currentAuthAccessToken() == nil)
        #expect(await currentAuthRefreshToken() == nil)
    }

    @Test func signOutRejectsMigrationCapturedBeforeCoordinatorRegistration() async throws {
        try await TestInfrastructure.prepare()

        let legacyAuthState = AuthState(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: "legacy-refresh-token"
        )
        await MainActor.run {
            Context.currentContext.store.dispatch(SetAuthState(payload: legacyAuthState))
        }

        let migrationCaptured = AsyncTestSignal()
        let releaseMigration = AsyncTestSignal()
        let originalAuthenticator = Context.currentContext.authenticator
        Context.currentContext.authenticator = Authenticator(
            migrateLegacySessionIfNeeded: { authState in
                await migrationCaptured.signal()
                await releaseMigration.wait()
                await LegacySessionMigrator.migrateIfNeeded(authState: authState)
            }
        )
        defer { Context.currentContext.authenticator = originalAuthenticator }

        let accessTokenTask = Task { try await Rownd.getAccessToken() }
        await migrationCaptured.wait()

        await Rownd.signOut()
        await releaseMigration.signal()
        let accessToken = try await accessTokenTask.value

        #expect(accessToken == nil)
        #expect(await !SuperTokensSessionBridge.doesSessionExist())
        #expect(await currentAuthAccessToken() == nil)
    }

    @Test func migrationWithoutRefreshHeaderDoesNotCreatePartialSession() async throws {
        try await TestInfrastructure.prepare()
        try await setMigrationMode("migrateWithoutRefreshHeader")

        try await migrateLegacySession(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: "legacy-refresh-token"
        )

        #expect(await !SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
        #expect(SuperTokensSessionBridge.getRefreshToken() == nil)
        #expect(SuperTokensSessionBridge.getFrontToken() == nil)
        #expect(await currentAuthRefreshToken() == "legacy-refresh-token")

        let counters = try await getJSON(path: "counters")
        #expect(counters["migrate"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)
    }

    @Test func expiredLegacySessionRefreshesThenMigratesThroughHarness() async throws {
        try await TestInfrastructure.prepare()

        try await migrateLegacySession(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: -3600).timeIntervalSince1970),
            refreshToken: "legacy-refresh-token"
        )

        #expect(await SuperTokensSessionBridge.doesSessionExist())

        let counters = try await getJSON(path: "counters")
        #expect(counters["migrate"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 1)
    }

    @Test func legacyRefreshFailureSignsOutAndDoesNotCallMigrate() async throws {
        try await TestInfrastructure.prepare()
        try await setMigrationMode("legacyRefreshFailure")

        try await migrateLegacySession(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: -3600).timeIntervalSince1970),
            refreshToken: "legacy-refresh-token"
        )

        #expect(await !SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
        #expect(await currentAuthAccessToken() == nil)
        #expect(await currentAuthRefreshToken() == nil)

        let counters = try await getJSON(path: "counters")
        #expect(counters["legacyRefresh"] as? Int == 1)
        #expect(counters["migrate"] as? Int == 0)
    }

    @Test func migrateUnauthorizedSignsOutLocalLegacySession() async throws {
        try await TestInfrastructure.prepare()
        try await setMigrationMode("migrate401")

        try await migrateLegacySession(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: "legacy-refresh-token"
        )

        #expect(await !SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
        #expect(await currentAuthAccessToken() == nil)
        #expect(await currentAuthRefreshToken() == nil)

        let counters = try await getJSON(path: "counters")
        #expect(counters["legacyRefresh"] as? Int == 0)
        #expect(counters["migrate"] as? Int == 1)

        let capturedRequests = try await getJSON(path: "captured-requests")
        let migrateRequest = try #require(capturedRequests["migrate"] as? [String: Any])
        let authorization = try #require(migrateRequest["authorization"] as? String)
        #expect(authorization.hasPrefix("Bearer "))
        #expect(migrateRequest["authorizationCount"] as? Int == 1)
        #expect(migrateRequest["rowndAppKey"] as? String == nil)
    }

    @Test func migrationClientMapsConflictToSessionAlreadyExists() async throws {
        try await TestInfrastructure.prepare()
        try await setMigrationMode("migrate409")

        let result = try await LegacySessionMigrationClient(
            apiDomain: TestInfrastructure.supertokensConfig.apiDomain,
            apiBasePath: TestInfrastructure.supertokensConfig.apiBasePath
        ).migrate(legacyAccessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970))

        #expect(result == .sessionAlreadyExists)

        let counters = try await getJSON(path: "counters")
        #expect(counters["migrate"] as? Int == 1)

        let capturedRequests = try await getJSON(path: "captured-requests")
        let migrateRequest = try #require(capturedRequests["migrate"] as? [String: Any])
        let authorization = try #require(migrateRequest["authorization"] as? String)
        #expect(authorization.hasPrefix("Bearer "))
        #expect(migrateRequest["authorizationCount"] as? Int == 1)
        #expect(migrateRequest["rowndAppKey"] as? String == nil)
    }

    @Test func googleSignInCreatesSuperTokensSessionWithoutLegacyRefresh() async throws {
        try await TestInfrastructure.prepare()

        let response = try await SuperTokensThirdPartySignInClient(
            apiDomain: TestInfrastructure.supertokensConfig.apiDomain,
            apiBasePath: TestInfrastructure.supertokensConfig.apiBasePath
        ).signInWithGoogle(idToken: "fake-google-id-token")

        #expect(response.userType == .NewUser)
        #expect(await SuperTokensSessionBridge.doesSessionExist())
        let accessToken = try #require(await SuperTokensSessionBridge.getAccessToken())
        #expect(!accessToken.isEmpty)

        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()
        #expect(try await Rownd.getAccessToken(throwIfMissing: true) == accessToken)

        let counters = try await getJSON(path: "counters")
        #expect(counters["googleSignIn"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)

        let capturedRequests = try await getJSON(path: "captured-requests")
        let googleRequest = try #require(capturedRequests["googleSignIn"] as? [String: Any])
        #expect(googleRequest["authorization"] as? String == nil)
        #expect(googleRequest["authorizationCount"] as? Int == 0)
        #expect(googleRequest["rowndAppKey"] as? String == nil)

        let body = try #require(googleRequest["body"] as? [String: Any])
        #expect(body["thirdPartyId"] as? String == "google")
        let tokens = try #require(body["oAuthTokens"] as? [String: Any])
        #expect(tokens["id_token"] as? String == "fake-google-id-token")
    }

    @Test func appleSignInCreatesSuperTokensSessionWithoutLegacyRefresh() async throws {
        try await TestInfrastructure.prepare()

        let response = try await SuperTokensThirdPartySignInClient(
            apiDomain: TestInfrastructure.supertokensConfig.apiDomain,
            apiBasePath: TestInfrastructure.supertokensConfig.apiBasePath
        ).signInWithApple(authorizationCode: "fake-apple-auth-code")

        #expect(response.userType == .NewUser)
        #expect(await SuperTokensSessionBridge.doesSessionExist())
        let accessToken = try #require(await SuperTokensSessionBridge.getAccessToken())
        #expect(!accessToken.isEmpty)

        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()
        #expect(try await Rownd.getAccessToken(throwIfMissing: true) == accessToken)

        let counters = try await getJSON(path: "counters")
        #expect(counters["appleSignIn"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)

        let capturedRequests = try await getJSON(path: "captured-requests")
        let appleRequest = try #require(capturedRequests["appleSignIn"] as? [String: Any])
        #expect(appleRequest["authorization"] as? String == nil)
        #expect(appleRequest["authorizationCount"] as? Int == 0)
        #expect(appleRequest["rowndAppKey"] as? String == nil)

        let body = try #require(appleRequest["body"] as? [String: Any])
        #expect(body["thirdPartyId"] as? String == "apple")
        #expect(body["clientType"] == nil)
        #expect(body["oAuthTokens"] == nil)

        let redirectURIInfo = try #require(body["redirectURIInfo"] as? [String: Any])
        let queryParams = try #require(redirectURIInfo["redirectURIQueryParams"] as? [String: Any])
        #expect(queryParams["code"] as? String == "fake-apple-auth-code")
    }

    @Test func userProfileRoutesUseSuperTokensPluginHeaders() async throws {
        try await TestInfrastructure.prepare()
        let email = uniqueEmail(prefix: "ios-profile")
        _ = try await createProfileSession(email: email, firstName: "Test")
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()

        let user = try await hydrateUserProfile()
        #expect(user.data["first_name"]?.value as? String == "Test")
        #expect(user.data["email"]?.value as? String == email)

        Context.currentContext.store.dispatch(UserData.save(["first_name": AnyCodable("Updated")]))
        _ = try await waitForCapturedRequest(named: "userUpdate")
        try await waitForUserLoadingToFinish()

        Context.currentContext.store.dispatch(UserData.saveMetaData(["tier": AnyCodable("pro")]))
        _ = try await waitForCapturedRequest(named: "userMetaUpdate")

        let counters = try await getJSON(path: "counters")
        #expect((counters["userGet"] as? Int ?? 0) >= 1)
        #expect(counters["legacyRefresh"] as? Int == 0)

        let capturedRequests = try await getJSON(path: "captured-requests")
        try assertSuperTokensOnlyHeaders(capturedRequests["userGet"] as? [String: Any])
        try assertSuperTokensOnlyHeaders(capturedRequests["userUpdate"] as? [String: Any])
        try assertSuperTokensOnlyHeaders(capturedRequests["userMetaUpdate"] as? [String: Any])

        let userUpdate = try #require(capturedRequests["userUpdate"] as? [String: Any])
        let userBody = try #require(userUpdate["body"] as? [String: Any])
        let userData = try #require(userBody["data"] as? [String: Any])
        #expect(userData.count == 1)
        #expect(userData["user_id"] == nil)
        #expect(userData["first_name"] as? String == "Updated")
        #expect(userUpdate["statusCode"] as? Int == 200)

        let metaUpdate = try #require(capturedRequests["userMetaUpdate"] as? [String: Any])
        let metaBody = try #require(metaUpdate["body"] as? [String: Any])
        let meta = try #require(metaBody["meta"] as? [String: Any])
        #expect(meta["tier"] as? String == "pro")
        #expect(metaUpdate["statusCode"] as? Int == 200)

        let persistedProfile = try await getJSON(path: "auth/plugin/rownd/user")
        let persistedData = try #require(persistedProfile["data"] as? [String: Any])
        let persistedMeta = try #require(persistedProfile["meta"] as? [String: Any])
        #expect(persistedData["first_name"] as? String == "Updated")
        #expect(persistedData["email"] as? String == email)
        #expect(persistedMeta["tier"] as? String == "pro")
    }

    @Test func emailEditRemainsPendingUntilVerification() async throws {
        try await TestInfrastructure.prepare()
        let initialEmail = uniqueEmail(prefix: "ios-email-pending-old")
        let editedEmail = uniqueEmail(prefix: "ios-email-pending-new")
        let userId = try await createProfileSession(email: initialEmail, firstName: "Existing")
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()
        _ = try await hydrateUserProfile()

        Rownd.user.set(field: "email", value: AnyCodable(editedEmail))

        let updateRequest = try await waitForEmailUpdateRequest()
        try assertSuccessfulSingleEmailUpdate(updateRequest, email: editedEmail)
        try assertSuperTokensOnlyHeaders(updateRequest)
        let verification = try await waitForVerificationEmail()
        #expect(verification["email"] as? String == editedEmail)

        try await waitForUserLoadingToFinish()
        let localEmail: String? = Rownd.user.get(field: "email")
        let localFirstName: String? = Rownd.user.get(field: "first_name")
        #expect(localEmail == initialEmail)
        #expect(localFirstName == "Existing")

        let profile = try await getJSON(path: "auth/plugin/rownd/user")
        try assertEmailProfile(
            profile,
            userId: userId,
            email: initialEmail,
            verifiedEmail: initialEmail,
            firstName: "Existing"
        )
        #expect(await SuperTokensSessionBridge.doesSessionExist())
    }

    @Test func verifyingEditedEmailUpdatesTheUserProfile() async throws {
        try await TestInfrastructure.prepare()
        let initialEmail = uniqueEmail(prefix: "ios-email-verified-old")
        let editedEmail = uniqueEmail(prefix: "ios-email-verified-new")
        let userId = try await createProfileSession(email: initialEmail, firstName: "Existing")
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()
        _ = try await hydrateUserProfile()

        Rownd.user.set(field: "email", value: AnyCodable(editedEmail))

        let updateRequest = try await waitForEmailUpdateRequest()
        try assertSuccessfulSingleEmailUpdate(updateRequest, email: editedEmail)
        try assertSuperTokensOnlyHeaders(updateRequest)
        let verification = try await waitForVerificationEmail()
        #expect(verification["email"] as? String == editedEmail)
        let link = try #require(verification["link"] as? String)
        let verificationResponse = try await verifyEmail(link: link)
        #expect(verificationResponse.body["status"] as? String == "OK")

        let profile = try await getJSON(path: "auth/plugin/rownd/user")
        try assertEmailProfile(
            profile,
            userId: userId,
            email: editedEmail,
            verifiedEmail: editedEmail,
            firstName: "Existing"
        )

        _ = try await hydrateUserProfile()
        let localEmail: String? = Rownd.user.get(field: "email")
        #expect(localEmail == editedEmail)

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["userId"] as? String == userId)
    }

    @Test func verifiedEmailChangeLinksPasswordlessToThirdPartyOnlyAccount() async throws {
        try await TestInfrastructure.prepare()

        let signIn = try await SuperTokensThirdPartySignInClient(
            apiDomain: TestInfrastructure.supertokensConfig.apiDomain,
            apiBasePath: TestInfrastructure.supertokensConfig.apiBasePath
        ).signInWithGoogle(idToken: "fake-google-id-token")
        #expect(signIn.userType == .NewUser)
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()
        _ = try await hydrateUserProfile()

        let originalAccessToken = try #require(await SuperTokensSessionBridge.getAccessToken())
        let originalRefreshToken = try #require(SuperTokensSessionBridge.getRefreshToken())
        let originalFrontToken = try #require(SuperTokensSessionBridge.getFrontToken())
        let originalAccount = try await getJSON(path: "test/account")
        let userId = try #require(originalAccount["userId"] as? String)
        let originalSessionHandle = try #require(originalAccount["sessionHandle"] as? String)
        let originalMethods = try #require(originalAccount["loginMethods"] as? [[String: Any]])
        let originalProvider = try #require(
            originalMethods.first { $0["recipeId"] as? String == "thirdparty" }
        )
        let originalProviderRecipeUserId = try #require(originalProvider["recipeUserId"] as? String)
        let originalProviderId = try #require(originalProvider["thirdPartyId"] as? String)
        let originalProviderUserId = try #require(originalProvider["thirdPartyUserId"] as? String)
        let originalProviderEmail = try #require(originalProvider["email"] as? String)
        #expect(originalMethods.count == 1)
        let targetEmail = uniqueEmail(prefix: "ios-thirdparty-email")
        Rownd.user.set(field: "email", value: AnyCodable(targetEmail))

        let updateRequest = try await waitForEmailUpdateRequest()
        try assertSuccessfulSingleEmailUpdate(updateRequest, email: targetEmail)
        try assertSuperTokensOnlyHeaders(updateRequest)
        let verification = try await waitForVerificationEmail()
        #expect(verification["email"] as? String == targetEmail)
        let deliveredToken = try #require(verification["token"] as? String)
        let link = try #require(verification["link"] as? String)
        let verificationResponse = try await verifyEmail(link: link)
        #expect(verificationResponse.body["status"] as? String == "OK")
        #expect(verificationResponse.token == deliveredToken)

        let replacementAccessToken = try #require(
            header(verificationResponse.response, named: "st-access-token")
        )
        let replacementRefreshToken = try #require(
            header(verificationResponse.response, named: "st-refresh-token")
        )
        let replacementFrontToken = try #require(
            header(verificationResponse.response, named: "front-token")
        )
        #expect(replacementAccessToken != originalAccessToken)
        #expect(replacementRefreshToken != originalRefreshToken)
        #expect(replacementFrontToken != originalFrontToken)
        #expect(await SuperTokensSessionBridge.getAccessToken() == replacementAccessToken)
        #expect(SuperTokensSessionBridge.getRefreshToken() == replacementRefreshToken)
        #expect(SuperTokensSessionBridge.getFrontToken() == replacementFrontToken)
        #expect(try await Rownd.getAccessToken(throwIfMissing: true) == replacementAccessToken)

        let capturedRequests = try await getJSON(path: "captured-requests")
        let emailVerify = try #require(capturedRequests["emailVerify"] as? [String: Any])
        let verificationAuthorization = try #require(emailVerify["authorization"] as? String)
        #expect(try sessionHandle(fromAuthorization: verificationAuthorization) == originalSessionHandle)
        #expect(emailVerify["authorizationCount"] as? Int == 1)
        #expect(emailVerify["rowndAppKey"] == nil)
        #expect(emailVerify["pendingVerificationId"] as? String == verificationResponse.pendingVerificationId)
        let verifyBody = try #require(emailVerify["body"] as? [String: Any])
        #expect(verifyBody["token"] as? String == deliveredToken)
        let responseSessionHeaders = try #require(emailVerify["responseSessionHeaders"] as? [String: Any])
        #expect(responseSessionHeaders["accessToken"] as? Bool == true)
        #expect(responseSessionHeaders["refreshToken"] as? Bool == true)
        #expect(responseSessionHeaders["frontToken"] as? Bool == true)

        let updatedAccount = try await getJSON(path: "test/account")
        #expect(updatedAccount["userId"] as? String == userId)
        let replacementSessionHandle = try #require(updatedAccount["sessionHandle"] as? String)
        let activeSessionHandles = try #require(updatedAccount["sessionHandles"] as? [String])
        #expect(replacementSessionHandle != originalSessionHandle)
        #expect(activeSessionHandles == [replacementSessionHandle])

        let updatedMethods = try #require(updatedAccount["loginMethods"] as? [[String: Any]])
        let updatedProvider = try #require(
            updatedMethods.first { $0["recipeId"] as? String == "thirdparty" }
        )
        let passwordlessMethod = try #require(
            updatedMethods.first {
                $0["recipeId"] as? String == "passwordless" &&
                    $0["email"] as? String == targetEmail
            }
        )
        #expect(updatedMethods.count == 2)
        #expect(updatedProvider["recipeUserId"] as? String == originalProviderRecipeUserId)
        #expect(updatedProvider["thirdPartyId"] as? String == originalProviderId)
        #expect(updatedProvider["thirdPartyUserId"] as? String == originalProviderUserId)
        #expect(updatedProvider["email"] as? String == originalProviderEmail)
        #expect(passwordlessMethod["verified"] as? Bool == true)

        let profile = try await getJSON(path: "auth/plugin/rownd/user")
        let profileData = try #require(profile["data"] as? [String: Any])
        let verifiedData = try #require(profile["verified_data"] as? [String: Any])
        #expect(profileData["email"] as? String == targetEmail)
        #expect(verifiedData["email"] as? String == targetEmail)

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["status"] as? String == "OK")
        #expect(protected["userId"] as? String == userId)
    }

    private func createHarnessSession(userId: String) async throws -> String {
        let session = try await createHarnessSessionResponse(userId: userId, captureLocally: true)
        #expect(session.response.statusCode == 200)
        return session.userId
    }

    private func createHarnessSessionResponse(
        userId: String,
        captureLocally: Bool
    ) async throws -> (response: HTTPURLResponse, userId: String) {
        var request = URLRequest(url: TestInfrastructure.backendURL.appendingPathComponent("test/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("header", forHTTPHeaderField: "st-auth-mode")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userId": userId])

        let session: URLSession
        if captureLocally {
            session = .shared
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = []
            session = URLSession(configuration: configuration)
        }

        let (data, response) = try await session.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        let statusCode = httpResponse.statusCode
        #expect(statusCode == 200)

        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["status"] as? String == "OK")

        return (httpResponse, try #require(payload["userId"] as? String))
    }

    private func createProfileSession(email: String, firstName: String) async throws -> String {
        var request = URLRequest(url: TestInfrastructure.backendURL.appendingPathComponent("test/profile-session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "firstName": firstName,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        #expect(statusCode == 200)

        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["status"] as? String == "OK")
        return try #require(payload["userId"] as? String)
    }

    private func hydrateUserProfile() async throws -> UserStateResponse {
        let user = try #require(try await UserData.fetchUserData(Context.currentContext.store.state))
        await MainActor.run {
            Context.currentContext.store.dispatch(SetUserState(payload: user.toUserState()))
        }
        return user
    }

    private func migrateLegacySession(accessToken: String, refreshToken: String) async throws {
        await MainActor.run {
            Context.currentContext.store.dispatch(
                SetAuthState(payload: AuthState(accessToken: accessToken, refreshToken: refreshToken))
            )
        }

        await LegacySessionMigrator.migrateIfNeeded(
            authState: Context.currentContext.store.state.auth,
            dependencies: LegacySessionMigrationDependencies(
                client: LegacySessionMigrationClient(
                    apiDomain: TestInfrastructure.supertokensConfig.apiDomain,
                    apiBasePath: TestInfrastructure.supertokensConfig.apiBasePath,
                    legacyApiDomain: TestInfrastructure.supertokensConfig.apiDomain
                )
            )
        )
    }

    private func setMigrationMode(_ mode: String) async throws {
        var request = URLRequest(url: TestInfrastructure.backendURL.appendingPathComponent("test/migration-mode"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["mode": mode])

        let (_, response) = try await URLSession.shared.data(for: request)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        #expect(statusCode == 200)
    }

    private func waitForCounter(_ name: String, expectedValue: Int) async throws {
        for _ in 0..<40 {
            let counters = try await getJSON(path: "counters")
            if counters[name] as? Int == expectedValue {
                return
            }

            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let counters = try await getJSON(path: "counters")
        #expect(counters[name] as? Int == expectedValue)
    }

    private func waitForEmailUpdateRequest() async throws -> [String: Any] {
        for _ in 0..<80 {
            let capturedRequests = try await getJSON(path: "captured-requests")
            if let request = capturedRequests["userFieldUpdate"] as? [String: Any],
               request["statusCode"] is Int {
                return request
            }
            if let request = capturedRequests["userUpdate"] as? [String: Any],
               request["statusCode"] is Int {
                return request
            }

            try await Task.sleep(nanoseconds: 25_000_000)
        }

        throw RowndError("Timed out waiting for the email update request")
    }

    private func waitForCapturedRequest(named name: String) async throws -> [String: Any] {
        for _ in 0..<80 {
            let capturedRequests = try await getJSON(path: "captured-requests")
            if let request = capturedRequests[name] as? [String: Any],
               request["statusCode"] is Int {
                return request
            }

            try await Task.sleep(nanoseconds: 25_000_000)
        }

        throw RowndError("Timed out waiting for the \(name) request")
    }

    private func waitForUserLoadingToFinish() async throws {
        for _ in 0..<80 {
            let isLoading = await MainActor.run {
                Context.currentContext.store.state.user.isLoading
            }
            if !isLoading {
                return
            }

            try await Task.sleep(nanoseconds: 25_000_000)
        }

        throw RowndError("Timed out waiting for the user profile update")
    }

    private func waitForVerificationEmail() async throws -> [String: Any] {
        for _ in 0..<80 {
            let verification = try await getJSON(path: "test/email-verification/latest")
            if verification["status"] as? String == "OK" {
                return verification
            }

            try await Task.sleep(nanoseconds: 25_000_000)
        }

        throw RowndError("Timed out waiting for the email verification message")
    }

    private func assertSuccessfulSingleEmailUpdate(_ request: [String: Any], email: String) throws {
        try #require(request["statusCode"] as? Int == 200)

        let body = try #require(request["body"] as? [String: Any])
        if request["field"] as? String == "email" {
            #expect(body.count == 1)
            #expect(body["value"] as? String == email)
            return
        }

        let data = try #require(body["data"] as? [String: Any])
        #expect(data.count == 1)
        #expect(data["email"] as? String == email)
    }

    private func assertEmailProfile(
        _ profile: [String: Any],
        userId: String,
        email: String,
        verifiedEmail: String,
        firstName: String
    ) throws {
        let data = try #require(profile["data"] as? [String: Any])
        let verifiedData = try #require(profile["verified_data"] as? [String: Any])
        #expect(data["user_id"] as? String == userId)
        #expect(data["email"] as? String == email)
        #expect(data["first_name"] as? String == firstName)
        #expect(verifiedData["email"] as? String == verifiedEmail)
    }

    private func verifyEmail(link: String) async throws -> (
        body: [String: Any],
        response: HTTPURLResponse,
        token: String,
        pendingVerificationId: String
    ) {
        let linkComponents = try #require(URLComponents(string: link))
        #expect(linkComponents.path == "/account/verify-email")
        let queryItems = linkComponents.queryItems ?? []
        let tokenItems = queryItems.filter { $0.name == "token" }
        try #require(tokenItems.count == 1)
        let token = try #require(tokenItems[0].value)
        try #require(!token.isEmpty)
        #expect(!token.hasPrefix("rownd-pending-email-v1."))
        let pendingVerificationItems = queryItems.filter {
            $0.name == "rowndPendingVerificationId"
        }
        try #require(pendingVerificationItems.count == 1)
        let pendingVerificationId = try #require(pendingVerificationItems[0].value)
        try #require(!pendingVerificationId.isEmpty)

        var endpoint = try #require(URLComponents(
            url: TestInfrastructure.backendURL.appendingPathComponent("auth/user/email/verify"),
            resolvingAgainstBaseURL: false
        ))
        endpoint.queryItems = [
            URLQueryItem(
                name: "rowndPendingVerificationId",
                value: pendingVerificationId
            )
        ]
        var request = URLRequest(url: try #require(endpoint.url))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "method": "token",
            "token": token,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        #expect(statusCode == 200)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (
            body,
            try #require(response as? HTTPURLResponse),
            token,
            pendingVerificationId
        )
    }

    private func uniqueEmail(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())@example.com"
    }

    private func assertSuperTokensOnlyHeaders(_ request: [String: Any]?) throws {
        let request = try #require(request)
        let authorization = try #require(request["authorization"] as? String)
        #expect(authorization.hasPrefix("Bearer "))
        #expect(request["authorizationCount"] as? Int == 1)
        #expect(request["rowndAppKey"] as? String == nil)
    }

    private func sessionHandle(fromAuthorization authorization: String) throws -> String {
        let prefix = "Bearer "
        try #require(authorization.hasPrefix(prefix))
        let accessToken = String(authorization.dropFirst(prefix.count))
        let segments = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        try #require(segments.count == 3)

        var encodedPayload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encodedPayload.append(String(repeating: "=", count: (4 - encodedPayload.count % 4) % 4))

        let payloadData = try #require(Data(base64Encoded: encodedPayload))
        let payload = try #require(
            try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        return try #require(payload["sessionHandle"] as? String)
    }

    private func getJSON(path: String) async throws -> [String: Any] {
        let url = TestInfrastructure.backendURL.appendingPathComponent(path)
        let (data, response) = try await URLSession.shared.data(from: url)
        let statusCode = try #require((response as? HTTPURLResponse)?.statusCode)
        #expect(statusCode == 200)

        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func generateJwt(expires: TimeInterval) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let payload: [String: Any] = [
            "sub": "legacy-rownd-user",
            "exp": Int(expires),
        ]

        let headerData = try! JSONSerialization.data(withJSONObject: header)
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)

        return [
            headerData.urlSafeBase64EncodedString(),
            payloadData.urlSafeBase64EncodedString(),
            "signature",
        ].joined(separator: ".")
    }

    private func header(_ response: HTTPURLResponse, named name: String) -> String? {
        response.allHeaderFields.first { key, _ in
            (key as? String)?.caseInsensitiveCompare(name) == .orderedSame
        }?.value as? String
    }

    @MainActor private func currentAuthAccessToken() -> String? {
        Context.currentContext.store.state.auth.accessToken
    }

    @MainActor private func currentAuthRefreshToken() -> String? {
        Context.currentContext.store.state.auth.refreshToken
    }

    private func clearLocalSuperTokensSessionArtifacts() {
        SuperTokensSessionBridge.clearLocalSessionArtifacts()
    }
}

private actor AsyncTestSignal {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor AsyncTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private extension Data {
    func urlSafeBase64EncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
