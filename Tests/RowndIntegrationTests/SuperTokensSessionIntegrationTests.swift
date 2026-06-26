import Foundation
import Testing
import AnyCodable

@testable import SuperTokensRownd

@Suite(.serialized) struct SuperTokensSessionIntegrationTests {
    @Test func pluginAppConfigRouteIsServedBySuperTokensHarness() async throws {
        try await TestInfrastructure.prepare()

        let appConfig = try await getJSON(path: "auth/plugin/rownd/app-config")

        #expect(appConfig["status"] as? String == "OK")
        #expect(appConfig["id"] as? String == "app_test_rownd_ios")
        #expect(appConfig["name"] as? String == "Rownd iOS Integration Tests")
    }

    @Test func urlProtocolCapturesSessionHeadersFromSuperTokensResponse() async throws {
        try await TestInfrastructure.prepare()

        try await createHarnessSession(userId: "ios-session-capture-user")

        #expect(await SuperTokensSessionBridge.doesSessionExist())
        let accessToken = try #require(await SuperTokensSessionBridge.getAccessToken())
        #expect(!accessToken.isEmpty)
    }

    @Test func capturedSessionCanCallProtectedRouteAndSignOut() async throws {
        try await TestInfrastructure.prepare()

        try await createHarnessSession(userId: "ios-protected-user")

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["status"] as? String == "OK")
        #expect(protected["userId"] as? String == "ios-protected-user")

        await SuperTokensSessionBridge.signOut()

        #expect(await !SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == nil)
    }

    @Test func signOutAllCallsPluginSignoutAndClearsLocalSession() async throws {
        try await TestInfrastructure.prepare()

        try await createHarnessSession(userId: "ios-signout-all-user")
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

        try await createHarnessSession(userId: "ios-refresh-user")

        let response = try await getJSON(path: "test/refresh-once")
        #expect(response["status"] as? String == "OK")
        #expect(response["userId"] as? String == "ios-refresh-user")

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

        let response = try await createHarnessSessionResponse(userId: "ios-hub-bootstrap-user", captureLocally: false)
        let accessToken = try #require(header(response, named: "st-access-token"))

        clearLocalSuperTokensSessionArtifacts()
        #expect(await !SuperTokensSessionBridge.doesSessionExist())

        await Task.detached(priority: .userInitiated) {
            SuperTokensSessionBridge.bootstrapSession(
                accessToken: accessToken,
                refreshToken: header(response, named: "st-refresh-token"),
                frontToken: header(response, named: "front-token"),
                antiCSRF: header(response, named: "anti-csrf")
            )
        }.value
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()

        #expect(await SuperTokensSessionBridge.doesSessionExist())
        #expect(await SuperTokensSessionBridge.getAccessToken() == accessToken)

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["status"] as? String == "OK")
        #expect(protected["userId"] as? String == "ios-hub-bootstrap-user")

        let counters = try await getJSON(path: "counters")
        #expect(counters["legacyRefresh"] as? Int == 0)
        #expect(counters["migrate"] as? Int == 0)

        let capturedRequests = try await getJSON(path: "captured-requests")
        let protectedRequest = try #require(capturedRequests["protected"] as? [String: Any])
        #expect(protectedRequest["authorizationCount"] as? Int == 1)
        #expect(protectedRequest["rowndAppKey"] as? String == nil)
    }

    @Test func validLegacySessionMigratesThroughHarness() async throws {
        try await TestInfrastructure.prepare()

        try await migrateLegacySession(
            accessToken: generateJwt(expires: Date(timeIntervalSinceNow: 3600).timeIntervalSince1970),
            refreshToken: "legacy-refresh-token"
        )

        #expect(await SuperTokensSessionBridge.doesSessionExist())

        let counters = try await getJSON(path: "counters")
        #expect(counters["migrate"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)

        let protected = try await getJSON(path: "test/protected")
        #expect(protected["status"] as? String == "OK")
        #expect(protected["userId"] as? String == "ios-test-user")
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
        try await createHarnessSession(userId: "ios-profile-user")
        await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()

        let user = try await UserData.fetchUserData(Context.currentContext.store.state)
        #expect(user?.data["first_name"]?.value as? String == "Test")

        Context.currentContext.store.dispatch(UserData.save(["first_name": AnyCodable("Updated")]))
        try await waitForCounter("userUpdate", expectedValue: 1)

        Context.currentContext.store.dispatch(UserData.saveMetaData(["tier": AnyCodable("pro")]))
        try await waitForCounter("userMetaUpdate", expectedValue: 1)

        let counters = try await getJSON(path: "counters")
        #expect(counters["userGet"] as? Int == 1)
        #expect(counters["legacyRefresh"] as? Int == 0)

        let capturedRequests = try await getJSON(path: "captured-requests")
        try assertSuperTokensOnlyHeaders(capturedRequests["userGet"] as? [String: Any])
        try assertSuperTokensOnlyHeaders(capturedRequests["userUpdate"] as? [String: Any])
        try assertSuperTokensOnlyHeaders(capturedRequests["userMetaUpdate"] as? [String: Any])

        let userUpdate = try #require(capturedRequests["userUpdate"] as? [String: Any])
        let userBody = try #require(userUpdate["body"] as? [String: Any])
        let userData = try #require(userBody["data"] as? [String: Any])
        #expect(userData["first_name"] as? String == "Updated")

        let metaUpdate = try #require(capturedRequests["userMetaUpdate"] as? [String: Any])
        let metaBody = try #require(metaUpdate["body"] as? [String: Any])
        let meta = try #require(metaBody["meta"] as? [String: Any])
        #expect(meta["tier"] as? String == "pro")
    }

    private func createHarnessSession(userId: String) async throws {
        let response = try await createHarnessSessionResponse(userId: userId, captureLocally: true)
        #expect(response.statusCode == 200)
    }

    private func createHarnessSessionResponse(userId: String, captureLocally: Bool) async throws -> HTTPURLResponse {
        var request = URLRequest(url: TestInfrastructure.backendURL.appendingPathComponent("test/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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

        return httpResponse
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

    private func assertSuperTokensOnlyHeaders(_ request: [String: Any]?) throws {
        let request = try #require(request)
        let authorization = try #require(request["authorization"] as? String)
        #expect(authorization.hasPrefix("Bearer "))
        #expect(request["authorizationCount"] as? Int == 1)
        #expect(request["rowndAppKey"] as? String == nil)
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
        let userDefaults = UserDefaults.standard
        userDefaults.removeObject(forKey: "st-storage-item-st-access-token")
        userDefaults.removeObject(forKey: "st-storage-item-st-refresh-token")
        userDefaults.removeObject(forKey: "supertokens-ios-fronttoken-key")
        userDefaults.removeObject(forKey: "st-storage-item-st-last-access-token-update")
        userDefaults.removeObject(forKey: "supertokens-ios-anticsrf-key")
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
