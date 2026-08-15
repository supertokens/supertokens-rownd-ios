//
//  AppDelegate.swift
//  ios native
//
//  Created by Matt Hamann on 6/23/22.
//

import Foundation
import SwiftUI
import Rownd
import Lottie
import WidgetKit
import AnyCodable
import WebKit

struct E2EHarnessConfig: Decodable {
    struct SuperTokens: Decodable {
        struct AppInfo: Decodable {
            let apiDomain: String
            let apiBasePath: String
        }

        let appInfo: AppInfo
    }

    let apiUrl: String
    let appKey: String
    let hubBaseUrl: String
    let supertokens: SuperTokens
}

@MainActor
final class E2EReadiness: ObservableObject {
    static let shared = E2EReadiness()

    @Published private(set) var isReady = false
    @Published private(set) var signInCompletedCount = 0

    private init() {}

    func markReady() {
        isReady = true
    }

    func record(_ event: RowndEvent) {
        if event.event == .signInCompleted {
            signInCompletedCount += 1
        }
    }
}

final class E2EEventRecorder: RowndEventHandlerDelegate {
    static let shared = E2EEventRecorder()

    private init() {}

    func handleRowndEvent(_ event: RowndEvent) {
        Task { @MainActor in
            E2EReadiness.shared.record(event)
        }
    }
}

enum E2ESupport {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ROWND_E2E"] == "1"
    }

    static var configURL: URL {
        URL(string: ProcessInfo.processInfo.environment["ROWND_E2E_CONFIG_URL"] ?? "http://127.0.0.1:3100/config")!
    }

    static var apiURL: URL? {
        guard let url = UserDefaults.standard.string(forKey: "ROWND_E2E_API_URL") else { return nil }
        return URL(string: url)
    }

    static func loadConfig() async throws -> E2EHarnessConfig {
        let (data, _) = try await URLSession.shared.data(from: configURL)
        return try JSONDecoder().decode(E2EHarnessConfig.self, from: data)
    }

    static func sessionHandle(from accessToken: String?) -> String? {
        guard let accessToken else { return nil }
        let parts = accessToken.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["sessionHandle"] as? String
    }

    static func configureRownd(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) async {
        do {
            let shouldResetSession = ProcessInfo.processInfo.environment["ROWND_E2E_RESET_SESSION"] == "1"
            if shouldResetSession {
                await clearWebsiteData()
            }

            let config = try await loadConfig()
            UserDefaults.standard.set(config.apiUrl, forKey: "ROWND_E2E_API_URL")

            Rownd.config.baseUrl = config.hubBaseUrl
            Rownd.config.subdomainExtension = ExampleAppConfig.subdomainExtension
            Rownd.config.appGroupPrefix = ExampleAppConfig.appGroupPrefix
            Rownd.config.enableDebugMode = ExampleAppConfig.enableDebugMode
            Rownd.config.enableSmartLinkPasteBehavior = false
            Rownd.config.customizations = AppCustomizations()
            Rownd.config.customizations.loadingAnimation = LottieAnimation.named("loading")
            Rownd.addEventHandler(RowndEventHandler())
            Rownd.addEventHandler(E2EEventRecorder.shared)

            await Rownd.configure(
                launchOptions: launchOptions,
                appKey: config.appKey,
                supertokens: RowndSuperTokensConfig(
                    appName: "Rownd iOS E2E",
                    apiDomain: config.supertokens.appInfo.apiDomain,
                    apiBasePath: config.supertokens.appInfo.apiBasePath
                )
            )

            if shouldResetSession {
                await Rownd.signOut()
            }

            if let deepLink = ProcessInfo.processInfo.environment["ROWND_E2E_DEEP_LINK"] {
                guard let deepLinkURL = URL(string: deepLink),
                      Rownd.handleSmartLink(url: deepLinkURL) else {
                    throw E2EError.invalidDeepLink
                }
            }

            await E2EReadiness.shared.markReady()
        } catch {
            fatalError("Failed to configure Rownd E2E harness: \(error)")
        }
    }

    @MainActor
    private static func clearWebsiteData() async {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    static func resetHarness() async throws {
        guard let apiURL = apiURL else { return }
        var request = URLRequest(url: apiURL.appendingPathComponent("reset"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        try requireOK(data: data, response: response)
    }

    static func createSession() async throws {
        guard let apiURL = apiURL else { throw E2EError.missingApiURL }
        let environment = ProcessInfo.processInfo.environment
        let email = environment["ROWND_E2E_EMAIL"] ?? "ios-e2e-user@example.com"
        let firstName = environment["ROWND_E2E_FIRST_NAME"] ?? "Existing"
        var request = URLRequest(url: apiURL.appendingPathComponent("test/profile-session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("header", forHTTPHeaderField: "st-auth-mode")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": email,
            "firstName": firstName
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try requireOK(data: data, response: response)
        _ = try await Rownd.getAccessToken(throwIfMissing: true)
    }

    static func updateProfile() async throws {
        guard let apiURL = apiURL else { throw E2EError.missingApiURL }
        var request = URLRequest(url: apiURL.appendingPathComponent("auth/plugin/rownd/user"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "data": [
                "first_name": "E2E"
            ]
        ])

        _ = try await URLSession.shared.data(for: request)
        Rownd.user.set(data: [
            "first_name": AnyCodable("E2E")
        ])
    }

    private static func requireOK(data: Data, response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["status"] as? String == "OK" else {
            throw E2EError.unexpectedResponse
        }
    }
}

enum E2EError: Error {
    case invalidDeepLink
    case missingApiURL
    case unexpectedResponse
}

struct E2EStatusView: View {
    @StateObject var authState = Rownd.getInstance().state().subscribe { $0.auth }
    @StateObject var user = Rownd.getInstance().state().subscribe { $0.user.data }
    @StateObject private var readiness = E2EReadiness.shared

    var body: some View {
        if E2ESupport.isEnabled {
            VStack {
                Text(readiness.isReady ? "ready" : "loading")
                    .accessibilityIdentifier("e2e-sdk-state")
                Text(authState.current.isAuthenticated ? "authenticated" : "signed-out")
                    .accessibilityIdentifier("e2e-auth-state")
                Text(E2ESupport.sessionHandle(from: authState.current.accessToken) ?? "no-session")
                    .accessibilityIdentifier("e2e-session-handle")
                Text((user.current["user_id"]?.value as? String) ?? "no-user")
                    .accessibilityIdentifier("e2e-user-id")
                Text(authState.current.challengeId == nil ? "clear" : "active")
                    .accessibilityIdentifier("e2e-challenge-state")
                Text(String(readiness.signInCompletedCount))
                    .accessibilityIdentifier("e2e-sign-in-completed-count")
            }
        }
    }
}

class AppCustomizations: RowndCustomizations {
//    override var sheetBackgroundColor: UIColor {
//        return UIColor(red: 225/255, green: 225/255, blue: 225/255, alpha: 1.0)
//    }
}

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        if E2ESupport.isEnabled {
            Task {
                await E2ESupport.configureRownd(launchOptions: launchOptions)
                WidgetCenter.shared.reloadAllTimelines()
            }

            return true
        }

        Rownd.config.baseUrl = ExampleAppConfig.hubBaseUrl
        Rownd.config.subdomainExtension = ExampleAppConfig.subdomainExtension
        Rownd.config.appGroupPrefix = ExampleAppConfig.appGroupPrefix
        Rownd.config.enableDebugMode = ExampleAppConfig.enableDebugMode

        Rownd.config.customizations = AppCustomizations()
//        Rownd.config.customizations.loadingAnimationUiView = CustomLoadingAnimationView()
        Rownd.config.customizations.loadingAnimation = LottieAnimation.named("loading")

        Rownd.addEventHandler(RowndEventHandler())

        Task {
            await Rownd.configure(
                launchOptions: launchOptions,
                appKey: ExampleAppConfig.appKey,
                supertokens: RowndSuperTokensConfig(
                    appName: "Rownd iOS All Authentication Methods",
                    apiDomain: ExampleAppConfig.apiDomain,
                    apiBasePath: ExampleAppConfig.apiBasePath
                )
            )
            _ = try? await Rownd.getAccessToken()
            WidgetCenter.shared.reloadAllTimelines()
        }

        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return Rownd.handleSmartLink(url: url)
    }

    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Get URL components from the incoming user activity.
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let incomingURL = userActivity.webpageURL,
              let components = NSURLComponents(url: incomingURL, resolvingAgainstBaseURL: true) else {
            return false
        }

        return Rownd.handleSignInLink(url: incomingURL)
    }

    func scene(_ scene: UIScene, willConnectTo
               session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {

        // Get URL components from the incoming user activity.
        guard let userActivity = connectionOptions.userActivities.first,
              userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let incomingURL = userActivity.webpageURL,
              let components = NSURLComponents(url: incomingURL, resolvingAgainstBaseURL: true) else {
            return
        }

        Rownd.handleSignInLink(url: incomingURL)
    }
}
