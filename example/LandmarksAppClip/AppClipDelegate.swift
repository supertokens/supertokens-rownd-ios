import Foundation
import UIKit
import Rownd

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        Rownd.config.baseUrl = "https://hub.dev.rownd.io"
        Rownd.config.apiUrl = "https://api.dev.rownd.io"
        Rownd.config.subdomainExtension = ".dev.rownd.link"
        Rownd.config.appGroupPrefix = "group.rowndexample"

        Task {
            await Rownd.configure(
                launchOptions: launchOptions,
                appKey: "key_pko8eul59xz33hr21jgxvx6s",
                supertokens: RowndSuperTokensConfig(
                    appName: "Example App",
                    apiDomain: "https://api.example.com"
                )
            )
        }

        return true
    }
}
