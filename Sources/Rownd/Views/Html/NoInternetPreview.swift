#if DEBUG
import SwiftUI
import WebKit

/// The Hub renders its web view transparently over the sheet, which supplies the
/// background color — the offline HTML sets a text color but never a background.
/// Previews mirror that, otherwise dark mode draws white text on a white web view.
private struct TransparentWebView: UIViewRepresentable {
    let html: String

    // Spelled out as `UIViewRepresentableContext` rather than the usual `Context`,
    // because Rownd declares its own `Context` type that shadows the associated one.
    func makeUIView(context: UIViewRepresentableContext<TransparentWebView>) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: UIViewRepresentableContext<TransparentWebView>) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

/// The offline HTML on the sheet background it is shown against in the Hub.
private struct OfflineScreenPreview: View {
    let html: String
    let darkMode: Bool

    var body: some View {
        TransparentWebView(html: html)
            .background(Color(darkMode ? Constants.BACKGROUND_DARK : Constants.BACKGROUND_LIGHT))
    }
}

/// Builds an app config that pins dark mode and the primary color, so a preview
/// doesn't inherit the ambient trait collection the way the live screen does.
@MainActor private func previewAppConfig(
    darkMode: Bool,
    primaryColor: String
) -> AppConfigState {
    var customizations = AppHubCustomizationsConfigState()
    customizations.darkMode = darkMode ? "enabled" : "disabled"
    customizations.primaryColor = primaryColor
    customizations.primaryColorDarkMode = primaryColor

    var hub = AppHubConfigState()
    hub.customizations = customizations

    var config = AppConfigConfig()
    config.hub = hub

    var appConfig = AppConfigState()
    appConfig.config = config
    return appConfig
}

/// `NoInternetHTML` reads its font size from `Rownd.config`, which captures the
/// scaled value once at init, so a preview can't drive it with `sizeCategory` the
/// way a SwiftUI view would. Setting it here is how a larger text size is previewed.
@MainActor private func offlineScreen(
    darkMode: Bool,
    primaryColor: String = "#5b13df",
    fontSize: CGFloat = RowndCustomizations.scaledDefaultFontSize()
) -> some View {
    Rownd.config.customizations.defaultFontSize = fontSize
    let html = NoInternetHTML(
        appConfig: previewAppConfig(darkMode: darkMode, primaryColor: primaryColor),
        host: "{appName}.rownd-hub.supertokens.com",
        errorCode: URLError.notConnectedToInternet.rawValue
    )
    return OfflineScreenPreview(html: html, darkMode: darkMode)
}

struct NoInternet_Previews: PreviewProvider {
    static var previews: some View {
        offlineScreen(darkMode: false)
            .previewDisplayName("Light")

        offlineScreen(darkMode: true)
            .previewDisplayName("Dark")

        offlineScreen(darkMode: true, primaryColor: "#f5c26b")
            .previewDisplayName("Dark, branded")

        offlineScreen(darkMode: false, fontSize: 24)
            .previewDisplayName("Light, large text")
    }
}
#endif
