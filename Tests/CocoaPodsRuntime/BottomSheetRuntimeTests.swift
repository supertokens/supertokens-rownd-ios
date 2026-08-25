import UIKit
import XCTest
import Rownd

@MainActor
final class BottomSheetRuntimeTests: XCTestCase {
    func testVendoredBottomSheetPresentsAndNotifiesBeforeDismissal() async {
        XCTAssertTrue(NSClassFromString("RowndLBBottomSheetController") === BottomSheetController.self)
        XCTAssertEqual(NSStringFromClass(BottomSheetController.self), "RowndLBBottomSheetController")

        let forwardingEventsViewClass = NSClassFromString("RowndLBBottomSheetForwardingEventsView")
        XCTAssertNotNil(forwardingEventsViewClass)

        let packagingBundle = Bundle(for: BottomSheetController.self)
        let resourceBundleURL = packagingBundle.url(forResource: "RowndLBBottomSheet", withExtension: "bundle")
        XCTAssertNotNil(resourceBundleURL)
        XCTAssertNotNil(resourceBundleURL.flatMap(Bundle.init(url:))?.url(forResource: "BottomSheet", withExtension: "storyboardc"))
        XCTAssertNil(packagingBundle.url(forResource: "BottomSheet", withExtension: "storyboardc"))

        let window = UIWindow(frame: UIScreen.main.bounds)
        defer {
            window.isHidden = true
        }

        let host = UIViewController()
        let content = UIViewController()
        let dismissalObserver = DismissalObserverViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()

        let sheet = host.presentAsBottomSheet(
            content,
            bottomSheetInteractionDelegate: dismissalObserver
        )
        await nextRunLoop()

        XCTAssertIdentical(host.presentedViewController, sheet)
        XCTAssertTrue(sheet.isViewLoaded)
        XCTAssertTrue(type(of: sheet.view) === forwardingEventsViewClass)
        XCTAssertIdentical(content.bottomSheetController, sheet)
        XCTAssertIdentical(content.parent, sheet)
        XCTAssertTrue(content.view.isDescendant(of: sheet.view))

        window.isHidden = true
        window.rootViewController = nil
        XCTAssertNil(sheet.viewIfLoaded?.window)
        XCTAssertIdentical(host.presentedViewController, sheet)

        sheet.dismiss()
        XCTAssertTrue(dismissalObserver.willDismiss)
    }

    private func nextRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}

private final class DismissalObserverViewController: UIViewController, BottomSheetInteractionDelegate {
    private(set) var willDismiss = false

    func bottomSheetInteractionDidTapOutside() {}

    func bottomSheetInteractionWillDismiss() {
        willDismiss = true
    }
}
