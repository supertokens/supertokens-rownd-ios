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

class AppCustomizations: RowndCustomizations {
//    override var sheetBackgroundColor: UIColor {
//        return UIColor(red: 225/255, green: 225/255, blue: 225/255, alpha: 1.0)
//    }
}

class AppDelegate: NSObject, UIApplicationDelegate {

    var authRepo: AuthRepository?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {

        Rownd.config.baseUrl = "https://hub.dev.rownd.io"
        Rownd.config.apiUrl = "https://api.dev.rownd.io"
        Rownd.config.subdomainExtension = ".dev.rownd.link"
        Rownd.config.appGroupPrefix = "group.rowndexample"

        Rownd.config.customizations = AppCustomizations()
//        Rownd.config.customizations.loadingAnimationUiView = CustomLoadingAnimationView()
        Rownd.config.customizations.loadingAnimation = LottieAnimation.named("loading")

        Rownd.addEventHandler(RowndEventHandler())

        Task {
            await Rownd.configure(
                launchOptions: launchOptions,
                appKey: "key_pko8eul59xz33hr21jgxvx6s",
                supertokens: RowndSuperTokensConfig(
                    appName: "Example App",
                    apiDomain: "https://api.example.com"
                )
            )
            _ = try? await Rownd.getAccessToken()
            WidgetCenter.shared.reloadAllTimelines()
        }

        authRepo = AuthRepository()

        return true
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {

        // TODO: handle URL from here
        Rownd.handleSignInLink(url: url)

        return true
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
