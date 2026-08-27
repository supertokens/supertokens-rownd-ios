//
//  CustomActivityViewController.swift
//  RowndSDK
//
//  Created by Matt Hamann on 7/14/22.
//

import UIKit
#if canImport(LBBottomSheet)
import LBBottomSheet
#endif

protocol BottomSheetControllerProtocol {
    var detents: [BottomSheetController.Behavior.HeightValue] { get set }
}

protocol BottomSheetHostProtocol {
    var hostController: BottomSheetViewController? { get set }
}

class BottomSheetViewController: UIViewController, BottomSheetInteractionDelegate {

    let debouncer = Debouncer(delay: 0.1) // 500ms
    var controller: UIViewController? {
        didSet {
            if oldValue !== controller,
               let oldHubViewController = oldValue as? HubViewController,
               oldHubViewController.hostController === self {
                oldHubViewController.hostController = nil
            }
            if oldValue == nil, controller != nil {
                didFinalizeDisappearance = false
            }
        }
    }
    var sheetController: BottomSheetController?
    var latestTargetHeight: CGFloat = 0.9
    var isKeyboardOpen = false
    private var didFinalizeDisappearance = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let controller = controller else {
            return
        }

        if var hubViewController = controller as? BottomSheetHostProtocol {
            hubViewController.hostController = self
        }

        var behavior: BottomSheetController.Behavior = .init(swipeMode: .full)
        if let controller = controller as? BottomSheetControllerProtocol {
            behavior.heightMode = .specific(values: controller.detents, heightLimit: .statusBar)
        } else {
            behavior.heightMode = .fitContent()
        }

        subscribeToNotification(UIResponder.keyboardWillShowNotification, selector: #selector(keyboardWillShow))
        subscribeToNotification(UIResponder.keyboardWillHideNotification, selector: #selector(keyboardWillHide))

        var theme: BottomSheetController.Theme = .init()
        theme.cornerRadius = Rownd.config.customizations.sheetCornerBorderRadius
        theme.shadow?.color = .systemGray6
        theme.dimmingBackgroundColor = UIColor.black.withAlphaComponent(CGFloat(0.25))

        theme.grabber?.topMargin = CGFloat(10.0)
        theme.grabber?.size = CGSize(width: 100.0, height: 5.0)

        sheetController = presentAsBottomSheet(
            controller,
            bottomSheetInteractionDelegate: self,
            theme: theme,
            behavior: behavior
        )

    }

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Unsubscribe from all our notifications
        unsubscribeFromAllNotifications()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard shouldFinalizeDisappearance else {
            return
        }
        let disappearingController = controller
        guard !finalizeDisappearanceIfDetached(for: disappearingController) else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.finalizeDisappearanceIfDetached(for: disappearingController)
        }
    }

    var shouldFinalizeDisappearance: Bool {
        isBeingDismissed || presentingViewController == nil
    }

    var isOuterHostDetached: Bool {
        presentingViewController == nil && viewIfLoaded?.window == nil
    }

    func outerDismissalDidComplete(for controller: UIViewController) {
        finalizeDisappearanceIfDetached(for: controller)
    }

    @discardableResult
    private func finalizeDisappearanceIfDetached(for expectedController: UIViewController?) -> Bool {
        guard let expectedController,
              controller === expectedController,
              !didFinalizeDisappearance,
              isOuterHostDetached else {
            return false
        }
        didFinalizeDisappearance = true
        let hubViewController = controller as? HubViewController
        controller = nil
        sheetController = nil
        hubViewController?.hostDidDisappear()
        return true
    }

    func updateBottomSheetHeight(_ number: CGFloat) {
        self.latestTargetHeight = number
        debouncer.debounce(action: triggerSheetHeightUpdate)
    }

    public func hideBottomSheet(_ completion: (() -> Void)? = nil) {
        guard let sheetController = sheetController else {
            completion?()
            return
        }
        sheetController.dismiss(completion)
    }

    func bottomSheetInteractionDidTapOutside() {}

    func bottomSheetInteractionWillDismiss() {
        (controller as? HubViewController)?.hostDismissalStarted()
    }

    private func triggerSheetHeightUpdate() {
        if let sheetController = sheetController {
            guard let controller = self.controller else {
                return
            }
            Task { @MainActor in
                guard let hubViewController = controller as? HubViewController else {
                    return
                }

                let targetHeight = self.isKeyboardOpen ? UIScreen.main.bounds.height * 0.90 : self.latestTargetHeight

                hubViewController.preferredHeightInBottomSheet = Double.minimum(targetHeight, UIScreen.main.bounds.height * 0.90)
                sheetController.preferredHeightInBottomSheetDidUpdate()
            }
        }
    }

    func canTouchDimmingBackgroundToDismiss(_ enable: Bool) {
        if let sheetController = sheetController {
            sheetController.setCanTouchDimmingBackgroundToDismiss(enable)
        }
    }
}

extension BottomSheetViewController {
    func subscribeToNotification(_ notification: NSNotification.Name, selector: Selector) {
        NotificationCenter.default.addObserver(self, selector: selector, name: notification, object: nil)
    }

    func unsubscribeFromAllNotifications() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func keyboardWillShow(notification: NSNotification) {
        // Get required info out of the notification
        self.isKeyboardOpen = true
        self.latestTargetHeight = UIScreen.main.bounds.height * 0.9
        debouncer.debounce(action: self.triggerSheetHeightUpdate)
    }

    @objc func keyboardWillHide(notification: NSNotification) {
        self.isKeyboardOpen = false
        debouncer.debounce(action: self.triggerSheetHeightUpdate)
    }
}
