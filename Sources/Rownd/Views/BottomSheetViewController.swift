//
//  CustomActivityViewController.swift
//  RowndSDK
//
//  Created by Matt Hamann on 7/14/22.
//

import UIKit
import LBBottomSheet

protocol BottomSheetControllerProtocol {
    var detents: [LBBottomSheet.BottomSheetController.Behavior.HeightValue] { get set }
}

protocol BottomSheetHostProtocol {
    var hostController: BottomSheetViewController? { get set }
}

class BottomSheetViewController: UIViewController {

    let debouncer = Debouncer(delay: 0.1) // 500ms
    var controller: UIViewController?
    var sheetController: LBBottomSheet.BottomSheetController?
    var latestTargetHeight: CGFloat = 0.9
    var isKeyboardOpen = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard let controller = controller else {
            return
        }

        if var hubViewController = controller as? BottomSheetHostProtocol {
            hubViewController.hostController = self
        }

        var behavior: LBBottomSheet.BottomSheetController.Behavior = .init(swipeMode: .full)
        if let controller = controller as? BottomSheetControllerProtocol {
            behavior.heightMode = .specific(values: controller.detents, heightLimit: .statusBar)
        } else {
            behavior.heightMode = .fitContent()
        }

        subscribeToNotification(UIResponder.keyboardWillShowNotification, selector: #selector(keyboardWillShow))
        subscribeToNotification(UIResponder.keyboardWillHideNotification, selector: #selector(keyboardWillHide))

        var theme: LBBottomSheet.BottomSheetController.Theme = .init()
        theme.cornerRadius = Rownd.config.customizations.sheetCornerBorderRadius
        theme.shadow?.color = .systemGray6
        theme.dimmingBackgroundColor = UIColor.black.withAlphaComponent(CGFloat(0.25))

        theme.grabber?.topMargin = CGFloat(10.0)
        theme.grabber?.size = CGSize(width: 100.0, height: 5.0)

        sheetController = presentAsBottomSheet(controller, theme: theme, behavior: behavior)

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
        (controller as? HubViewController)?.hostDidDisappear()
        self.controller = nil
        self.sheetController = nil
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
