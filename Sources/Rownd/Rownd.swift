//
//  Rownd.swift
//  framework
//
//  Created by Matt Hamann on 6/23/22.
//

import AnyCodable
import AuthenticationServices
import Foundation
import Get
import GoogleSignIn
import LBBottomSheet
import ReSwift
import SwiftUI
import SuperTokensIOS
import UIKit
import WebKit

public class Rownd: NSObject {
    private static let inst: Rownd = Rownd()
    public static var config: RowndConfig = RowndConfig()
    private let appStateListener = AppStateListener()

    public static let user = UserPropAccess()
    private static var appleSignUpCoordinator: AppleSignUpCoordinator = AppleSignUpCoordinator(inst)
    internal static var googleSignInCoordinator: GoogleSignInCoordinator = GoogleSignInCoordinator(
        inst)
    @MainActor private var _bottomSheetController: BottomSheetViewController?
    internal static var apiClient = RowndApi().client
    internal static let automationsCoordinator = AutomationsCoordinator()
    internal static var customerWebViews = CustomerWebViewManager()
    @MainActor private static var instantUsers: InstantUsers?
    internal static var isSuperTokensInitialized = false
    internal static var displayHubHandler: ((HubPageSelector, Encodable?) -> Void)?

    // Run processAutomations() every second to support time-based automations
    internal var automationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        Rownd.automationsCoordinator.processAutomations()
    }

    @discardableResult
    public static func configure(
        launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
        appKey: String?,
        supertokens: RowndSuperTokensConfig
    ) async -> RowndState {
        do {
            config.supertokens = try validateSuperTokensConfig(supertokens)
        } catch {
            fatalError("Invalid Rownd SuperTokens configuration: \(error)")
        }

        if let _appKey = appKey {
            config.appKey = _appKey
        }

        do {
            try initializeSuperTokensIfNeeded()
        } catch {
            fatalError("Failed to initialize SuperTokens: \(error)")
        }

        let state = await inst.inflateStoreCache()
        await LegacySessionMigrator.migrateIfNeeded(authState: state.auth)

        // Skip the rest within app extensions
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            return state
        }

        await inst.loadAppConfig()
        inst.loadAppleSignIn()

        // Start automations after initial app setup on the main actor
        await MainActor.run {
            Rownd.automationsCoordinator.start()
        }

        let store = Context.currentContext.store
        if store.state.isStateLoaded && !store.state.auth.isAuthenticated {
            SmartLinks.handleSmartLinkLaunchBehavior(launchOptions: launchOptions)

            if store.state.appConfig.config?.hub?.auth?.signInMethods?.google?.enabled == true {
                do {
                    _ = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
                    logger.debug("Successfully restored previous Google Sign-in")
                } catch {
                    logger.warning(
                        "Failed to restore previous Google Sign-in: \(String(describing: error))")
                }
            }

            if store.state.auth.challengeId != nil || store.state.auth.userIdentifier != nil {
                var authState = store.state.auth
                authState.challengeId = nil
                authState.userIdentifier = nil
                store.dispatch(SetAuthState(payload: authState))
            }

        }

        // Fetch user if authenticated and app is in foreground
        await MainActor.run {
            if store.state.auth.isAuthenticated && UIApplication.shared.applicationState == .active
            {
                store.dispatch(UserData.fetch())
            }

            instantUsers = InstantUsers(context: Context.currentContext)
            instantUsers?.tmpForceInstantUserConversionIfRequested()
        }

        return state
    }

    @available(*, deprecated, renamed: "handleSmartLink")
    @discardableResult
    public static func handleSignInLink(url: URL?) -> Bool {
        return SmartLinks.handleSmartLink(url: url)
    }

    @discardableResult
    public static func handleSmartLink(url: URL?) -> Bool {
        return SmartLinks.handleSmartLink(url: url)
    }

    public static func getInstance() -> Rownd {
        return inst
    }

    public static func requestSignIn() {
        requestSignIn(RowndSignInOptions())
    }

    public static func requestSignIn(with: RowndSignInHint, completion: (() -> Void)? = nil) {
        requestSignIn(with: with, signInOptions: RowndSignInOptions(), completion: completion)
    }

    public static func requestSignIn(
        with: RowndSignInHint, signInOptions: RowndSignInOptions?, completion: (() -> Void)? = nil
    ) {
        let signInOptions = determineSignInOptions(signInOptions)
        switch with {
        case .phone:
            requestSignIn(determineSignInOptions(signInOptions, signInType: SignInType.phone))
        case .email:
            requestSignIn(determineSignInOptions(signInOptions, signInType: SignInType.email))
        case .appleId:
            appleSignUpCoordinator.signIn(signInOptions?.intent)
        case .googleId:
            Task {
                await googleSignInCoordinator.signIn(
                    signInOptions?.intent,
                    hint: signInOptions?.hint
                )
                completion?()
            }
        case .guest, .anonymous:
            requestSignIn(determineSignInOptions(signInOptions, signInType: SignInType.anonymous))
        }

    }

    public static func requestSignIn(_ signInOptions: RowndSignInOptions?) {
        let signInOptions = determineSignInOptions(signInOptions)
        inst.displayHub(.signIn, jsFnOptions: signInOptions ?? RowndSignInOptions())
    }

    internal static func requestSignIn(jsFnOptions: Encodable?) {
        inst.displayHub(.signIn, jsFnOptions: jsFnOptions)
    }

    internal static func openHubDeepLink(_ url: URL) {
        config.pendingHubDeepLinkUrl = url
        inst.displayHub(.deepLink, jsFnOptions: nil)
    }

    public static func signOut(scope: RowndSignoutScope) throws {
        switch scope {
        case .all:
            Task {
                do {
                    try await Auth.signOutUser()
                    await performLocalSignOut()
                } catch {
                    logger.error(
                        "Failed to sign out user from all sessions: \(String(describing: error))")
                }
            }
        }

    }

    public static func signOut() {
        Task {
            await performLocalSignOut()
        }
    }

    internal static func signOutForMigrationFailure() async {
        await performLocalSignOut()
    }

    private static func performLocalSignOut() async {
        if isSuperTokensInitialized {
            // Keep the compatibility session from resurrecting Rownd auth on later syncs.
            await SuperTokensSessionBridge.signOut()
        }

        await MainActor.run {
            let store = Context.currentContext.store
            store.dispatch(SetAuthState(payload: AuthState()))
            RowndEventEmitter.emit(RowndEvent(event: .signOut))
        }
    }

    public static func manageAccount() {
        inst.displayHub(.manageAccount)
    }

    /// Registers a `WKWebView` instance with Rownd, injecting JavaScript bindings and
    /// setting up a message handler to enable communication between the web content and native Swift code.
    ///
    /// This is useful when embedding Rownd's web UI inside a web view and needing native-to-web communication.
    ///
    /// - Parameter webView: The `WKWebView` to register and prepare for use with Rownd.
    /// - Returns: A closure that can be called later to deregister the web view
    public static func registerWebView(_ webView: WKWebView) -> () -> Void {
        return customerWebViews.register(webView)
    }

    @discardableResult public static func getAccessToken(throwIfMissing: Bool = false) async throws
        -> String?
    {
        let store = Context.currentContext.store
        return try await store.state.auth.getAccessToken(throwIfMissing: throwIfMissing)
    }

    public func state() -> Store<RowndState> {
        return Context.currentContext.store
    }

    public static func addEventHandler(_ handler: RowndEventHandlerDelegate) {
        Context.currentContext.eventListeners.append(handler)
    }

    // This is an internal test function used only to manually test
    // ensuring refresh tokens are only used once when attempting
    // to fetch new access tokens
    @available(
        *, deprecated,
        message: "Internal test use only. This method may change any time without warning."
    )
    public static func _refreshToken() {
        Task {
            do {
                let refreshResp = try await Context.currentContext.authenticator.refreshToken()
                print("refresh 1: \(String(describing: refreshResp))")
            } catch {
                print("Error refreshing token 1: \(String(describing: error))")
            }
        }

        Task {
            do {
                let refreshResp = try await Context.currentContext.authenticator.refreshToken()
                print("refresh 2: \(String(describing: refreshResp))")
            } catch {
                print("Error refreshing token 2: \(String(describing: error))")
            }
        }

        Task {
            do {
                let refreshResp = try await Context.currentContext.authenticator.refreshToken()
                print("refresh 3: \(String(describing: refreshResp))")
            } catch {
                print("Error refreshing token 3: \(String(describing: error))")
            }
        }
    }

    internal static func determineSignInOptions(_ signInOptions: RowndSignInOptions?)
        -> RowndSignInOptions?
    {
        return determineSignInOptions(signInOptions, signInType: nil)
    }

    internal static func determineSignInOptions(
        _ signInOptions: RowndSignInOptions?, signInType: SignInType?
    ) -> RowndSignInOptions? {
        let store = Context.currentContext.store
        var signInOptions = signInOptions
        if signInOptions?.intent == RowndSignInIntent.signUp
            || signInOptions?.intent == RowndSignInIntent.signIn
        {
            if store.state.appConfig.config?.hub?.auth?.useExplicitSignUpFlow != true {
                signInOptions?.intent = nil
                logger.error(
                    "Sign in with intent: SignIn/SignUp is not enabled. Turn it on in the Rownd platform"
                )
            }
        }

        if signInType != nil {
            signInOptions?.signInType = signInType
        }

        return signInOptions
    }

    internal static func validateSuperTokensConfig(_ config: RowndSuperTokensConfig) throws
        -> RowndSuperTokensConfig
    {
        if config.appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RowndError("SuperTokens appName must not be empty")
        }

        if config.apiDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RowndError("SuperTokens apiDomain must not be empty")
        }

        if config.apiBasePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RowndError("SuperTokens apiBasePath must not be empty")
        }

        return config
    }

    internal static func requireSuperTokensConfig() throws -> RowndSuperTokensConfig {
        try config.requireSuperTokensConfig()
    }

    @discardableResult
    internal static func initializeSuperTokensIfNeeded() throws -> Bool {
        guard !isSuperTokensInitialized else {
            return false
        }

        let supertokens = try requireSuperTokensConfig()
        let debugEventHandler: ((EventType) -> Void)? = config.enableDebugMode ? { event in
            logger.debug("SuperTokens event: \(String(describing: event))")
        } : nil
        let debugPreAPIHook: ((APIAction, URLRequest) -> URLRequest)? = config.enableDebugMode ? { action, request in
            logger.debug("SuperTokens request: \(String(describing: action)) \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")")
            return request
        } : nil
        let debugPostAPIHook: ((APIAction, URLRequest, URLResponse?) -> Void)? = config.enableDebugMode ? { action, request, response in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            logger.debug("SuperTokens response: \(String(describing: action)) \(request.url?.absoluteString ?? "") status=\(String(describing: statusCode))")
        } : nil

        try SuperTokens.initialize(
            apiDomain: supertokens.apiDomain,
            apiBasePath: supertokens.apiBasePath,
            tokenTransferMethod: .header,
            eventHandler: debugEventHandler,
            preAPIHook: debugPreAPIHook,
            postAPIHook: debugPostAPIHook
        )

        URLProtocol.registerClass(SuperTokensURLProtocol.self)
        isSuperTokensInitialized = true
        return true
    }

    @MainActor internal var bottomSheetController: BottomSheetViewController {
        if let controller = _bottomSheetController {
            return controller
        }

        let controller = BottomSheetViewController()
        _bottomSheetController = controller
        return controller
    }

    // MARK: Internal methods
    private func loadAppleSignIn() {
        // If we want to check if the AppleId userIdentifier is still valid
    }

    private func loadAppConfig() async {
        let store = Context.currentContext.store
        if store.state.appConfig.id == nil {
            // Await the config if it wasn't already cached
            guard let appConfig = await AppConfig.fetch() else {
                return
            }

            Task { @MainActor in
                store.dispatch(SetAppConfig(payload: appConfig.app))
            }
        } else {
            Task { @MainActor in
                // Refresh in background if already present
                store.dispatch(AppConfig.requestAppState())
            }
        }

    }

    @discardableResult
    private func inflateStoreCache() async -> RowndState {
        let store = Context.currentContext.store
        return await store.state.load()
    }

    private func displayHub(_ page: HubPageSelector) {
        displayHub(page, jsFnOptions: nil)
    }

    private func displayHub(_ page: HubPageSelector, jsFnOptions: Encodable?) {
        if let displayHubHandler = Rownd.displayHubHandler {
            displayHubHandler(page, jsFnOptions)
            return
        }

        Task { @MainActor in
            let hubController = getHubViewController()
            displayViewControllerOnTop(hubController)
            hubController.loadNewPage(targetPage: page, jsFnOptions: jsFnOptions)
        }
    }

    @MainActor private func getHubViewController() -> HubViewController {
        if let hubViewController = bottomSheetController.controller as? HubViewController {
            return hubViewController
        }

        return HubViewController()
    }

    internal func getRootViewController() -> UIViewController? {
        return UIApplication.shared.connectedScenes
            .filter({ $0.activationState == .foregroundActive })
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows
            .filter({ $0.isKeyWindow }).first?.rootViewController
    }

    private func displayViewControllerOnTop(_ viewController: UIViewController) {
        Task { @MainActor in
            let rootViewController = getRootViewController()

            // Don't try to present again if it's already presented
            guard bottomSheetController.presentingViewController == nil else {
                return
            }

            // TODO: Eventually, replace this with native iOS 15+ sheetPresentationController
            // But, we can't replace it yet (2022) since there are too many devices running iOS 14.
            bottomSheetController.controller = viewController
            bottomSheetController.modalPresentationStyle = .overFullScreen

            rootViewController?.present(self.bottomSheetController, animated: true, completion: nil)
        }
    }

    @MainActor internal static func isDisplayingHub() -> Bool {
        return inst.bottomSheetController.controller != nil
            && inst.bottomSheetController.presentingViewController != nil
    }

}

public class UserPropAccess {
    private var store: Store<RowndState> {
        return Context.currentContext.store
    }
    public func get() -> UserState {
        return store.state.user.get()
    }

    public func get(field: String) -> Any {
        return store.state.user.get(field: field)
    }

    public func get<T>(field: String) -> T? {
        let value: T? = store.state.user.get(field: field)
        return value
    }

    public func set(data: [String: AnyCodable]) {
        store.state.user.set(data: data)
    }

    public func set(field: String, value: AnyCodable) {
        store.state.user.set(field: field, value: value)
    }

    public func isEncryptionPossible() throws {
        throw RowndError(
            "Encryption is currently not enabled with this SDK. If you like to enable it, please reach out to support@rownd.io"
        )
    }

    public func encrypt(plaintext: String) throws {
        throw RowndError(
            "Encryption is currently not enabled with this SDK. If you like to enable it, please reach out to support@rownd.io"
        )
    }

    public func decrypt(ciphertext: String) throws {
        throw RowndError(
            "Encryption is currently not enabled with this SDK. If you like to enable it, please reach out to support@rownd.io"
        )
    }
}

public enum RowndStateType {
    case auth, user, app, none
}

public enum UserFieldAccessType {
    case string, int, float, dictionary, array
}

public enum RowndSignInHint {
    case appleId, googleId, email, phone,
        guest, anonymous  // these two do the same thing
}

public struct RowndSignInOptions: Encodable {
    public init(
        postSignInRedirect: String? = Rownd.config.postSignInRedirect,
        intent: RowndSignInIntent? = nil, hint: String? = nil
    ) {
        self.postSignInRedirect = postSignInRedirect
        self.intent = intent
        self.hint = hint
    }

    public var postSignInRedirect: String? = Rownd.config.postSignInRedirect
    public var intent: RowndSignInIntent?
    public var hint: String?
    internal var signInType: SignInType?

    public var title: String?
    public var subtitle: String?

    enum CodingKeys: String, CodingKey {
        case intent
        case hint
        case postSignInRedirect = "post_login_redirect"
        case signInType = "sign_in_type"
        case title, subtitle
    }
}

public enum RowndSignInIntent: String, Codable {
    case signIn = "sign_in"
    case signUp = "sign_up"
}

public enum SignInType: String, Codable {
    case email = "email"
    case phone = "phone"
    case apple = "apple"
    case google = "google"
    case anonymous = "anonymous"
}

internal enum RowndSignInLoginStep: String, Codable {
    case initialize = "init"
    case noAccount = "no_account"
    case success = "success"
    case completing = "completing"
    case error = "error"
}

internal struct RowndSignInJsOptions: Encodable {
    public var token: String?
    public var loginStep: RowndSignInLoginStep?
    public var intent: RowndSignInIntent?
    public var userType: UserType?
    public var appVariantUserType: UserType?
    public var signInType: SignInType?
    public var challengeId: String?
    public var userIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case token, intent
        case loginStep = "login_step"
        case userType = "user_type"
        case appVariantUserType = "app_variant_user_type"
        case signInType = "sign_in_type"
        case challengeId = "request_id"
        case userIdentifier = "identifier"
    }
}

public enum Status: String, Codable {
    case loading
    case success
    case failed
}

struct RowndError: Error, CustomStringConvertible {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    public var description: String {
        return message
    }
}

public enum RowndSignoutScope: String, Codable {
    case all
}
