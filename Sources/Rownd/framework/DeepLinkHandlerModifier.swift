import SwiftUI

public struct RowndDeepLinkHandlerModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                logger.debug("SwiftUI onOpenURL received: \(url.absoluteString)")
                let handled = Rownd.handleSmartLink(url: url)
                logger.debug("SwiftUI onOpenURL handled by Rownd: \(handled)")
            }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                guard let url = userActivity.webpageURL else {
                    logger.debug("SwiftUI universal link activity missing URL")
                    return
                }
                logger.debug("SwiftUI universal link received: \(url.absoluteString)")
                let handled = Rownd.handleSmartLink(url: url)
                logger.debug("SwiftUI universal link handled by Rownd: \(handled)")
            }
    }
}

public extension View {
    func rowndDeepLinkHandler() -> some View {
        modifier(RowndDeepLinkHandlerModifier())
    }
}
