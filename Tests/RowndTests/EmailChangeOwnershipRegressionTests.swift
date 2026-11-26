import Foundation
import Testing
import WebKit
@testable import SuperTokensIOS
@testable import Rownd

@MainActor @Suite(.serialized) struct EmailChangeOwnershipRegressionTests {
    private static var descriptor: EmailChangeDescriptor {
        EmailChangeDescriptor(version: 2, requestId: "owned-request-123456", localDraft: emailChangeTestDraft,
                              expiresAt: (Date().addingTimeInterval(600).timeIntervalSince1970 * 1000).rounded())
    }

    private static var tokens: SuperTokensSessionTokens {
        let access = generateJwt(expires: Date().addingTimeInterval(3600).timeIntervalSince1970,
                                 sessionHandle: "owned-sr", userId: "owned-user")
        return SuperTokensSessionTokens(accessToken: access, refreshToken: "owned-refresh",
                                        frontToken: SuperTokensSessionBridge.buildFrontToken(from: access), antiCSRF: nil)
    }

    private func withSession(_ body: @escaping @MainActor () async throws -> Void) async throws {
        try await withGlobalTestLock { try await Self.runSession(body) }
    }

    private static func runSession(_ body: @MainActor () async throws -> Void) async throws {
        let originalConfig = Rownd.config
        let originalHandler = Rownd.displayHubHandler
        let originalInitialized = Rownd.isSuperTokensInitialized
        let originalStorage = SuperTokensSessionBridge.storageOverride
        let originalAuth = Context.currentContext.store.state.auth
        let originalUser = Context.currentContext.store.state.user
        let originalApp = Context.currentContext.store.state.appConfig
        SuperTokens.resetForTests()
        FrontToken.clearInMemoryCache()
        Rownd.isSuperTokensInitialized = false
        Rownd.config.supertokens = RowndSuperTokensConfig(appName: "owned-test", apiDomain: "https://api.example.test")
        Rownd.config.baseUrl = "https://hub.example.test"
        _ = try Rownd.initializeSuperTokensIfNeeded()
        let storage = InMemorySessionStore()
        SDKStorage.setTokenStorageForTests(storage)
        SuperTokensSessionBridge.storageOverride = storage
        Rownd.displayHubHandler = nil
        Rownd.emailChangeContinuation.clear()
        Context.currentContext.store.dispatch(SetAuthState(payload: AuthState()))
        Context.currentContext.store.dispatch(SetAppConfig(payload: AppConfigState(config: AppConfigConfig(
            hub: AppHubConfigState(auth: AppHubAuthConfigState(signInMethods: SignInMethods(
                apple: AppleSignInMethodConfig(iosClientType: "native-test")
            )))
        ))))
        let headers = ["st-access-token": tokens.accessToken, "st-refresh-token": tokens.refreshToken,
                       "front-token": tokens.frontToken, "Content-Type": "application/json"]
        OwnershipResponseProtocol.headers = headers
        SuperTokensURLProtocol.networkRequestExecutor = { request, completion in
            let isExchange = request.url?.path.hasSuffix("/signinup") == true
            let body = isExchange ? #"{"status":"OK","createdNewRecipeUser":false}"# : #"{"status":"OK","data":{"user_id":"owned-user"}}"#
            completion(Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                       headerFields: isExchange ? headers : [:]), nil)
        }
        SuperTokens.signOutRequestExecutor = { request, completion in
            completion(Data(#"{"status":"OK"}"#.utf8),
                       HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }
        defer {
            Rownd.emailChangeContinuation.clear()
            Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            _ = SuperTokensSessionBridge.clearLocalSessionArtifacts()
            SuperTokens.resetForTests()
            FrontToken.clearInMemoryCache()
            SuperTokensSessionBridge.storageOverride = originalStorage
            Rownd.isSuperTokensInitialized = originalInitialized
            Rownd.config = originalConfig
            Rownd.displayHubHandler = originalHandler
            Context.currentContext.store.dispatch(SetAuthState(payload: originalAuth))
            Context.currentContext.store.dispatch(SetUserState(payload: originalUser))
            Context.currentContext.store.dispatch(SetAppConfig(payload: originalApp))
        }
        try await body()
    }

    private static func presentOwnedSignIn() -> UUID {
        let owner = UUID()
        #expect(Rownd.emailChangeContinuation.begin(descriptor, configuration: Rownd.emailChangeConfiguration, owner: owner))
        #expect(Rownd.emailChangeContinuation.cleaned(owner: owner))
        Rownd.requestSignInForNativeCompletion(jsFnOptions: RowndSignInJsOptions(loginStep: .initialize), requestID: owner)
        return owner
    }

    private static func client() -> SuperTokensThirdPartySignInClient {
        let ordinary = URLSessionConfiguration.ephemeral
        ordinary.protocolClasses = [SuperTokensURLProtocol.self]
        let isolated = URLSessionConfiguration.ephemeral
        isolated.protocolClasses = [OwnershipResponseProtocol.self]
        return SuperTokensThirdPartySignInClient(apiDomain: "https://api.example.test", apiBasePath: "/auth",
            session: URLSession(configuration: ordinary), appleSession: URLSession(configuration: isolated))
    }

    private static func loadFixturePage(in hub: HubViewController, server: LocalHTTPServer) async throws {
        // Loading the parent view would start a second, SDK-owned navigation.
        hub.hubWebController.hubViewController = hub
        let loader = OwnershipPageLoader()
        try await loader.load(hub.hubWebController.webView, url: server.baseURL.appendingPathComponent("mobile_app"))
    }

    @Test func googleOwnedAttemptCannotBecomeOrdinaryAfterNewDirectAttempt() async throws {
        try await withSession {
            _ = Self.presentOwnedSignIn()
            let coordinator = GoogleSignInCoordinator(Rownd.getInstance(), signInClient: Self.client())
            coordinator.emitEvent = { _ in }
            coordinator.dispatchSignInActions = {}
            let oldAttempt = coordinator.beginAttempt(emitsSignInStarted: false)
            _ = coordinator.beginAttempt(emitsSignInStarted: true)
            let newerView = UUID()
            Rownd.requestSignInForNativeCompletion(jsFnOptions: nil, requestID: newerView)
            await coordinator.completeSignIn(idToken: "stale-proof", intent: .signIn, attemptID: oldAttempt)
            #expect(Rownd.isNativeHubRequestActive(newerView))
            #expect(!(await SuperTokensSessionBridge.doesSessionExist()))
            #expect(SuperTokensSessionBridge.getRefreshToken() == nil)
            #expect(!Context.currentContext.store.state.auth.isAuthenticated)
        }
    }

    @Test func googleTransportCannotDowngradeAfterContinuationDisappears() async throws {
        try await withSession {
            _ = Self.presentOwnedSignIn()
            let client = Self.client()
            let coordinator = GoogleSignInCoordinator(Rownd.getInstance(), signInClient: client)
            coordinator.emitEvent = { _ in }
            coordinator.dispatchSignInActions = {}
            let entered = OwnershipGate()
            let release = OwnershipGate()
            coordinator.signInWithGoogle = { token, context in
                await entered.open()
                await release.wait()
                return try await client.signInWithGoogle(idToken: token, context: context)
            }
            let attempt = coordinator.beginAttempt(emitsSignInStarted: false)
            let task = Task { await coordinator.completeSignIn(idToken: "proof", intent: .signIn, attemptID: attempt) }
            await entered.wait()
            let newerView = UUID()
            Rownd.requestSignInForNativeCompletion(jsFnOptions: nil, requestID: newerView)
            await release.open()
            await task.value
            #expect(Rownd.isNativeHubRequestActive(newerView))
            #expect(!(await SuperTokensSessionBridge.doesSessionExist()))
            #expect(SuperTokensSessionBridge.getRefreshToken() == nil)
            #expect(!Context.currentContext.store.state.auth.isAuthenticated)
        }
    }

    @Test(arguments: [false, true])
    func unexpectedAppleDismissalPreventsRealCredentialAdoption(beforeResponse: Bool) async throws {
        try await withSession {
            let owner = Self.presentOwnedSignIn()
            let coordinator = AppleSignUpCoordinator(Rownd.getInstance())
            let entered = OwnershipGate()
            let release = OwnershipGate()
            coordinator.signInWithApple = { _, _, _ in
                if beforeResponse { await entered.open(); await release.wait() }
                return SuperTokensAppleSignInResponse(status: "OK", createdNewRecipeUser: false, sessionTokens: Self.tokens)
            }
            coordinator.waitBeforeCompletion = {
                if !beforeResponse { await entered.open(); await release.wait() }
            }
            coordinator.syncAuthState = { identity, commit in
                await MainActor.run {
                    guard commit() else { return false }
                    Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(accessToken: identity.accessToken)))
                    return true
                }
            }
            coordinator.emitEvent = { _ in }
            let task = Task {
                await coordinator.completeSignIn(authorizationCode: "proof", fullName: nil, email: nil,
                                                 intent: .signIn, hubRequestID: owner)
            }
            await entered.wait()
            Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            await release.open()
            await task.value
            #expect(!(await SuperTokensSessionBridge.doesSessionExist()))
            #expect(SuperTokensSessionBridge.getRefreshToken() == nil)
            #expect(!Context.currentContext.store.state.auth.isAuthenticated)
        }
    }

    @Test func deliberateAppleDismissalStillAdoptsRealSessionAndResumesExactlyOnce() async throws {
        try await withSession {
            let owner = Self.presentOwnedSignIn()
            let coordinator = AppleSignUpCoordinator(Rownd.getInstance())
            coordinator.signInWithApple = { _, _, context in
                #expect(context == .emailChange)
                return SuperTokensAppleSignInResponse(status: "OK", createdNewRecipeUser: false, sessionTokens: Self.tokens)
            }
            coordinator.waitBeforeCompletion = {}
            coordinator.dismissHub = { _ in
                await MainActor.run { Rownd.getInstance().bottomSheetController.viewDidDisappear(false) }
            }
            coordinator.syncAuthState = { identity, commit in
                await MainActor.run {
                    guard commit() else { return false }
                    Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(accessToken: identity.accessToken)))
                    return true
                }
            }
            var completions = 0
            coordinator.emitEvent = { event in if event.event == .signInCompleted { completions += 1 } }
            await coordinator.completeSignIn(authorizationCode: "proof", fullName: nil, email: nil, intent: .signIn, hubRequestID: owner)
            #expect(await SuperTokensSessionBridge.doesSessionExist())
            #expect(SuperTokensSessionBridge.getRefreshToken() == Self.tokens.refreshToken)
            #expect(Context.currentContext.store.state.auth.isAuthenticated)
            #expect(Rownd.emailChangeContinuation.record?.phase == .resume)
            #expect(completions == 1)
            #expect((Rownd.getInstance().bottomSheetController.controller as? HubViewController)?.targetPage == .manageAccount)
        }
    }

    @Test func actualTrustedOTPMessageCannotInstallAfterOwnedViewDismissal() async throws {
        try await withSession {
            let server = try await LocalHTTPServer.start()
            defer { server.stop() }
            Rownd.config.baseUrl = server.baseURL.absoluteString
            _ = Self.presentOwnedSignIn()
            let source = try #require(Rownd.getInstance().bottomSheetController.controller as? HubViewController)
            let webController = source.hubWebController
            let gate = OwnershipGate()
            let release = OwnershipGate()
            defer { Task { await release.open() } }
            webController.beforeAuthenticationBootstrap = { await gate.open(); await release.wait() }
            try await Self.loadFixturePage(in: source, server: server)
            let message = try MessagePayload.AuthenticationMessage(accessToken: Self.tokens.accessToken,
                refreshToken: Self.tokens.refreshToken, frontToken: Self.tokens.frontToken).asJsonString()
            _ = try await webController.webView.evaluateJavaScript("window.webkit.messageHandlers.rowndIosSDK.postMessage(JSON.stringify({type:'authentication',payload:\(message)})); true;")
            await gate.wait()
            let acceptedTask = try #require(webController.authenticationTask)
            Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            await release.open()
            await acceptedTask.value
            #expect(!(await SuperTokensSessionBridge.doesSessionExist()))
            #expect(SuperTokensSessionBridge.getRefreshToken() == nil)
            #expect(!Context.currentContext.store.state.auth.isAuthenticated)
        }
    }

    @Test func mismatchedOwnedRetryRepliesRejectedWithoutSigningOutCurrentSession() async throws {
        try await withSession {
            let server = try await LocalHTTPServer.start()
            defer { server.stop() }
            Rownd.config.baseUrl = server.baseURL.absoluteString
            let owner = Self.presentOwnedSignIn()
            _ = await SuperTokensSessionBridge.adoptResponseSession(Self.tokens, permit: SuperTokensSessionBridge.captureAuthOperationPermit())
            Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(accessToken: Self.tokens.accessToken)))
            #expect(Rownd.emailChangeAuthenticationAdopted(owner: owner))
            Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            Rownd.resumeEmailChange(after: owner)
            let source = try #require(Rownd.getInstance().bottomSheetController.controller as? HubViewController)
            let web = source.hubWebController.webView
            try await Self.loadFixturePage(in: source, server: server)
            let wrong = EmailChangeDescriptor(version: 2, requestId: "wrong-request", localDraft: emailChangeTestDraft, expiresAt: Self.descriptor.expiresAt)
            let json = try wrong.asJsonString()
            _ = try await web.evaluateJavaScript("window.addEventListener('rownd:email-change-handoff', e => window.reply = e.detail); window.webkit.messageHandlers.rowndIosSDK.postMessage(JSON.stringify({type:'sign_in',payload:{was_user_initiated:true,email_change:\(json)}})); true;")
            var reply: [String: String]?
            for _ in 0..<100 {
                reply = try await web.evaluateJavaScript("window.reply || null") as? [String: String]
                if reply != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(reply == ["request_id": "wrong-request", "status": "REJECTED"])
            #expect(await SuperTokensSessionBridge.doesSessionExist())
            #expect(SuperTokensSessionBridge.getRefreshToken() == Self.tokens.refreshToken)
            #expect(Context.currentContext.store.state.auth.isAuthenticated)
            #expect(!Rownd.isSigningOut)
            #expect(Rownd.emailChangeContinuation.record?.descriptor.localDraft == Self.descriptor.localDraft)
        }
    }

    @Test func acceptedOTPBootstrapPermitIsRevokedByUnexpectedDismissal() async throws {
        try await withSession {
            _ = Self.presentOwnedSignIn()
            let acceptedPermit = SuperTokensSessionBridge.captureAuthOperationPermit()
            let tokens = Self.tokens
            Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            let installed = await Task.detached {
                SuperTokensSessionBridge.bootstrapSession(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
                    frontToken: tokens.frontToken, permit: acceptedPermit)
            }.value
            if installed { _ = await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens() }
            #expect(!installed)
            #expect(!(await SuperTokensSessionBridge.doesSessionExist()))
            #expect(SuperTokensSessionBridge.getRefreshToken() == nil)
            #expect(!Context.currentContext.store.state.auth.isAuthenticated)
        }
    }

    @Test func resumedFormIsDeliveredOnceAndNeverReinjectedIntoAnotherPresentation() async throws {
        try await withSession {
            let server = try await LocalHTTPServer.start()
            defer { server.stop() }
            Rownd.config.baseUrl = server.baseURL.absoluteString
            let owner = Self.presentOwnedSignIn()
            _ = await SuperTokensSessionBridge.adoptResponseSession(Self.tokens, permit: SuperTokensSessionBridge.captureAuthOperationPermit())
            Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(accessToken: Self.tokens.accessToken)))
            #expect(Rownd.emailChangeAuthenticationAdopted(owner: owner))
            Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            Rownd.resumeEmailChange(after: owner)
            let source = try #require(Rownd.getInstance().bottomSheetController.controller as? HubViewController)
            let controller = source.hubWebController
            try await Self.loadFixturePage(in: source, server: server)
            _ = try await controller.webView.evaluateJavaScript("window.deliveries = []; window.rownd = {user:{manageAccount(){ if(window.__rowndEmailChangeResume) deliveries.push(window.__rowndEmailChangeResume); delete window.__rowndEmailChangeResume; }}}; true")
            controller.webViewOnLoad(webView: controller.webView, targetPage: .manageAccount, jsFnOptions: nil)
            for _ in 0..<100 {
                if try await controller.webView.evaluateJavaScript("deliveries.length") as? Int == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(Rownd.emailChangeContinuation.record == nil)
            #expect(try await controller.webView.evaluateJavaScript("deliveries[0].local_draft.changes.email") as? String == "destination@example.test")
            controller.webViewOnLoad(webView: controller.webView, targetPage: .manageAccount, jsFnOptions: nil)
            try await Task.sleep(nanoseconds: 50_000_000)
            #expect(try await controller.webView.evaluateJavaScript("deliveries.length") as? Int == 1)
            Rownd.requestSignInForNativeCompletion(jsFnOptions: nil, requestID: UUID())
            Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            for _ in 0..<100 {
                if (Rownd.getInstance().bottomSheetController.controller as? HubViewController)?.hubWebController !== controller { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            await Task.yield()
            let replacement = try #require(Rownd.getInstance().bottomSheetController.controller as? HubViewController)
            #expect(replacement.hubWebController !== controller)
        }
    }

    @Test(arguments: ["subframe", "old", "oversize", "huge", "profile"])
    func invalidV2AdmissionLeavesSourceCredentialsUntouched(mode: String) async throws {
        try await withSession {
            let server = try await LocalHTTPServer.start()
            defer { server.stop() }
            Rownd.config.baseUrl = server.baseURL.absoluteString
            let owner = Self.presentOwnedSignIn()
            _ = await SuperTokensSessionBridge.adoptResponseSession(Self.tokens, permit: SuperTokensSessionBridge.captureAuthOperationPermit())
            Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(accessToken: Self.tokens.accessToken)))
            #expect(Rownd.emailChangeAuthenticationAdopted(owner: owner))
            Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            Rownd.resumeEmailChange(after: owner)
            let source = try #require(Rownd.getInstance().bottomSheetController.controller as? HubViewController)
            let web = source.hubWebController.webView
            try await Self.loadFixturePage(in: source, server: server)
            let saved = try #require(Rownd.emailChangeContinuation.record?.descriptor)
            let json = try saved.asJsonString()
            _ = try await web.evaluateJavaScript("window.addEventListener('rownd:email-change-handoff', e => window.rejection = e.detail.status); true")
            let script = mode == "profile"
                ? "window.webkit.messageHandlers.rowndIosSDK.postMessage(JSON.stringify({type:'user_data_update',payload:{data:{large_note:'a'.repeat(140000)}}}));"
                : "const envelope = \(json); \(mode == "old" ? "envelope.version = 1;" : "") \(mode == "oversize" || mode == "huge" ? "envelope.local_draft.changes.email = 'a'.repeat(\(mode == "huge" ? 140000 : 33000));" : "") window.webkit.messageHandlers.rowndIosSDK.postMessage(JSON.stringify({type:'sign_in',payload:{was_user_initiated:true,email_change:envelope}}));"
            if mode == "subframe" {
                let html = try "<script>\(script)</script>".asJsonString()
                _ = try await web.evaluateJavaScript("var f = document.createElement('iframe'); f.srcdoc = \(html); document.body.appendChild(f); true;")
            } else {
                _ = try await web.evaluateJavaScript("(() => { \(script) return true; })()")
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            #expect(try await web.evaluateJavaScript("window.rejection || null") as? String == (mode == "subframe" || mode == "profile" ? nil : "REJECTED"))
            if mode == "profile" {
                #expect((Context.currentContext.store.state.user.data["large_note"]?.value as? String)?.count == 140000)
            }
            #expect(!Rownd.isSigningOut)
            #expect(await SuperTokensSessionBridge.doesSessionExist())
            #expect(SuperTokensSessionBridge.getRefreshToken() == Self.tokens.refreshToken)
            #expect(Rownd.emailChangeContinuation.record?.phase == .resume)
        }
    }

    @Test func retryAfterActualFormTransferCleansCredentialsAndRestartsSignIn() async throws {
        try await withSession {
            let server = try await LocalHTTPServer.start()
            defer { server.stop() }
            Rownd.config.baseUrl = server.baseURL.absoluteString
            let owner = Self.presentOwnedSignIn()
            _ = await SuperTokensSessionBridge.adoptResponseSession(Self.tokens, permit: SuperTokensSessionBridge.captureAuthOperationPermit())
            Context.currentContext.store.dispatch(SetAuthState(payload: AuthState(accessToken: Self.tokens.accessToken)))
            #expect(Rownd.emailChangeAuthenticationAdopted(owner: owner))
            Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            Rownd.resumeEmailChange(after: owner)
            let source = try #require(Rownd.getInstance().bottomSheetController.controller as? HubViewController)
            let saved = try #require(Rownd.emailChangeContinuation.record?.descriptor)
            let web = source.hubWebController.webView
            try await Self.loadFixturePage(in: source, server: server)
            _ = try await web.evaluateJavaScript("window.rownd = {user:{manageAccount(){}}}; true")
            source.hubWebController.webViewOnLoad(webView: web, targetPage: .manageAccount, jsFnOptions: nil)
            for _ in 0..<100 {
                if try await web.evaluateJavaScript("window.__rowndEmailChangeResume?.request_id") as? String == saved.requestId { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(try await web.evaluateJavaScript("window.__rowndEmailChangeResume?.request_id") as? String == saved.requestId)
            #expect(Rownd.emailChangeContinuation.record == nil)
            // This fixture has no UIKit presenter to drive a hide completion.
            source.hostController = nil
            try #require(!Rownd.isSigningOut)
            try #require(Rownd.beginEmailChange(saved, source: source))
            Rownd.getInstance().bottomSheetController.viewDidDisappear(false)
            for _ in 0..<500 where Rownd.isSigningOut { try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(!Rownd.isSigningOut)
            #expect(Rownd.emailChangeContinuation.record?.phase == .signingIn)
            #expect(Rownd.emailChangeContinuation.record?.descriptor == saved)
            #expect(!(await SuperTokensSessionBridge.doesSessionExist()))
            #expect(SuperTokensSessionBridge.getRefreshToken() == nil)
            #expect(!Context.currentContext.store.state.auth.isAuthenticated)
        }
    }

}

@MainActor private final class OwnershipPageLoader: NSObject, WKNavigationDelegate {
    private var completion: CheckedContinuation<Void, Error>?
    func load(_ webView: WKWebView, url: URL) async throws {
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { completion in
            self.completion = completion
            webView.load(URLRequest(url: url))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        completion?.resume()
        completion = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error)
        completion = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion?.resume(throwing: error)
        completion = nil
    }
}

private actor OwnershipGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class OwnershipResponseProtocol: URLProtocol {
    static var headers: [String: String] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"OK","createdNewRecipeUser":false}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
