import Foundation
import UIKit
import SuperTokensRownd

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        Rownd.config.baseUrl = ExampleAppConfig.hubBaseUrl
        Rownd.config.subdomainExtension = ExampleAppConfig.subdomainExtension
        Rownd.config.appGroupPrefix = ExampleAppConfig.appGroupPrefix
        Rownd.config.enableDebugMode = ExampleAppConfig.enableDebugMode

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
        }

        return true
    }
}
