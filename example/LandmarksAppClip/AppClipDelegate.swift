import Foundation
import UIKit
import Rownd

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        Rownd.config.baseUrl = "https://staging.supertokens-rownd-hub.pages.dev"
        Rownd.config.apiUrl = "http://127.0.0.1:3137"
        Rownd.config.subdomainExtension = ".rownd.link"
        Rownd.config.appGroupPrefix = "group.rowndexample"
        Rownd.config.enableDebugMode = true

        Task {
            await Rownd.configure(
                launchOptions: launchOptions,
                appKey: "test_app_key",
                supertokens: RowndSuperTokensConfig(
                    appName: "Rownd iOS All Authentication Methods",
                    apiDomain: "http://127.0.0.1:3137",
                    apiBasePath: "/auth"
                )
            )
        }

        return true
    }
}
