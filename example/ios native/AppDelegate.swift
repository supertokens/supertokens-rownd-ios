//
//  AppDelegate.swift
//  ios native
//
//  Created by Matt Hamann on 6/23/22.
//

import Foundation
import SwiftUI
import SuperTokensRownd
import Lottie
import WidgetKit
import AnyCodable

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

    static func configureRownd(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) async {
        do {
            let config = try await loadConfig()
            UserDefaults.standard.set(config.apiUrl, forKey: "ROWND_E2E_API_URL")

            Rownd.config.baseUrl = config.hubBaseUrl
            Rownd.config.subdomainExtension = ExampleAppConfig.subdomainExtension
            Rownd.config.appGroupPrefix = ExampleAppConfig.appGroupPrefix
            Rownd.config.enableDebugMode = ExampleAppConfig.enableDebugMode
            Rownd.config.customizations = AppCustomizations()
            Rownd.config.customizations.loadingAnimation = LottieAnimation.named("loading")
            Rownd.addEventHandler(RowndEventHandler())

            await Rownd.configure(
                launchOptions: launchOptions,
                appKey: config.appKey,
                supertokens: RowndSuperTokensConfig(
                    appName: "Rownd iOS E2E",
                    apiDomain: config.supertokens.appInfo.apiDomain,
                    apiBasePath: config.supertokens.appInfo.apiBasePath
                )
            )
        } catch {
            fatalError("Failed to configure Rownd E2E harness: \(error)")
        }
    }

    static func resetHarness() async throws {
        guard let apiURL = apiURL else { return }
        var request = URLRequest(url: apiURL.appendingPathComponent("reset"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await URLSession.shared.data(for: request)
    }

    static func createSession(userId: String = "ios-e2e-user") async throws {
        guard let apiURL = apiURL else { throw E2EError.missingApiURL }
        var request = URLRequest(url: apiURL.appendingPathComponent("test/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userId": userId])

        _ = try await URLSession.shared.data(for: request)
        _ = try await Rownd.getAccessToken(throwIfMissing: true)
        Rownd.user.set(data: [
            "user_id": AnyCodable(userId),
            "email": AnyCodable("\(userId)@example.com")
        ])
    }

    static func updateProfile() async throws {
        guard let apiURL = apiURL else { throw E2EError.missingApiURL }
        var request = URLRequest(url: apiURL.appendingPathComponent("auth/plugin/rownd/user"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "data": [
                "user_id": "ios-e2e-user",
                "first_name": "E2E"
            ]
        ])

        _ = try await URLSession.shared.data(for: request)
        Rownd.user.set(data: [
            "user_id": AnyCodable("ios-e2e-user"),
            "first_name": AnyCodable("E2E")
        ])
    }
}

enum E2EError: Error {
    case missingApiURL
}

struct E2EStatusView: View {
    @StateObject var authState = Rownd.getInstance().state().subscribe { $0.auth }
    @StateObject var user = Rownd.getInstance().state().subscribe { $0.user.data }

    var body: some View {
        if E2ESupport.isEnabled {
            VStack {
                Text(authState.current.isAuthenticated ? "authenticated" : "signed-out")
                    .accessibilityIdentifier("e2e-auth-state")
                Text((user.current["user_id"]?.value as? String) ?? "no-user")
                    .accessibilityIdentifier("e2e-user-id")
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
