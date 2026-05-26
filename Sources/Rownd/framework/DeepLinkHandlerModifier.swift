import SwiftUI

public struct RowndDeepLinkHandlerModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                Rownd.handleSmartLink(url: url)
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                guard let url = userActivity.webpageURL else { return }
                Rownd.handleSmartLink(url: url)
            }
    }
}

public extension View {
    func rowndDeepLinkHandler() -> some View {
        modifier(RowndDeepLinkHandlerModifier())
    }
}
