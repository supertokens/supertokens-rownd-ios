//
//  HubViewController.swift
//  framework
//
//  Created by Matt Hamann on 7/5/22.
//

import Foundation
import SwiftUI
import UIKit
import Lottie

protocol HubViewProtocol {
    var targetPage: HubPageSelector { get set }

    func setLoading(_ isLoading: Bool)
    func show()
    func hide()
    func hide(completion: (() -> Void)?)
    func updateBottomSheetHeight(_ height: CGFloat)
    func canTouchDimmingBackgroundToDismiss(_ enable: Bool)
}

public class HubViewController: UIViewController, HubViewProtocol, BottomSheetHostProtocol {
    @objc var preferredHeightInBottomSheet: CGFloat = UIScreen.main.bounds.height * 0.3
    var activityIndicator = UIActivityIndicatorView(style: .large)
    var customLoadingAnimationView: UIView?
    var hubWebController = HubWebViewController()
    var targetPage = HubPageSelector.unknown
    weak var hostController: BottomSheetViewController?
    var isBottomSheetDismissing: Bool = false
    var presentationRequestID: UUID?
    var onDismissalStarted: ((UUID) -> Void)?
    var onDisappeared: ((UUID) -> Void)?
    private var hideCompletions: [() -> Void] = []
    private var isOuterDismissalScheduled = false

    static func buildHubLoaderUrl(
        baseUrl: String,
        config: RowndConfig,
        base64EncodedConfig: String,
        signInHash: String?
    ) -> URLComponents? {
        var hubLoaderUrl = URLComponents(string: "\(baseUrl)/mobile_app")
        hubLoaderUrl?.queryItems = [
            URLQueryItem(name: "config", value: base64EncodedConfig),
            URLQueryItem(name: "sign_in", value: signInHash ?? ""),
            URLQueryItem(name: "appKey", value: config.appKey),
            URLQueryItem(name: "apiDomain", value: config.supertokens.apiDomain),
            URLQueryItem(name: "apiBasePath", value: config.supertokens.apiBasePath)
        ] + (config.appVariantId.map { [URLQueryItem(name: "appVariantId", value: $0)] } ?? [])

        return hubLoaderUrl
    }
    
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

//        if let presentation = sheetPresentationController {
//            presentation.detents = [.medium(), .large()]
//            presentation.prefersGrabberVisible = true
//        }

        if let customLoadingAnimationView = customLoadingAnimationView {
            NSLayoutConstraint.activate([
                customLoadingAnimationView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                customLoadingAnimationView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }

        hubWebController.didMove(toParent: self)
        hubWebController.view.frame = view.bounds
        hubWebController.view.autoresizingMask = .flexibleHeight
    }

    @MainActor public func loadNewPage(targetPage: HubPageSelector, jsFnOptions: Encodable?) {
        self.targetPage = targetPage

        if targetPage == .deepLink {
            guard isViewLoaded else { return }
            if let url = Rownd.config.consumePendingHubDeepLinkUrl() {
                self.hubWebController.setUrl(url: url)
            }
            return
        }

        if let jsFnOptions = jsFnOptions {
            do {
                self.hubWebController.jsFunctionArgsAsJson = try jsFnOptions.asJsonString()
            } catch {
                logger.error("Failed to encode JS options to pass to function: \(String(describing: error))")
            }
        }

        if self.hubWebController.webView.url != nil {
            self.hubWebController.webViewOnLoad(webView: self.hubWebController.webView, targetPage: targetPage, jsFnOptions: jsFnOptions)
        }
    }

    public override func loadView() {
        hubWebController.hubViewController = self

        let base64EncodedConfig = Rownd.config.toJson()
            .data(using: .utf8)?
            .base64EncodedString(options: Data.Base64EncodingOptions(rawValue: 0)) ?? ""

        let store = Context.currentContext.store
        if targetPage == .deepLink, let pendingHubDeepLinkUrl = Rownd.config.consumePendingHubDeepLinkUrl() {
            view = UIView()
            view.backgroundColor = Rownd.config.customizations.sheetBackgroundColor
            initLoadingIndicator(view)
            hubWebController.setUrl(url: pendingHubDeepLinkUrl)
            addChild(hubWebController)
            view.addSubview(hubWebController.view)
            setupConstraints()
            return
        }

        guard let hubLoaderUrl = HubViewController.buildHubLoaderUrl(
            baseUrl: Rownd.config.baseUrl,
            config: Rownd.config,
            base64EncodedConfig: base64EncodedConfig,
            signInHash: store.state.signIn.toSignInHash()
        ) else {
            return
        }

        view = UIView()
        view.backgroundColor = Rownd.config.customizations.sheetBackgroundColor
        initLoadingIndicator(view)

        // This ensures that the Hub in the webview doesn't attempt to refresh its own tokens,
        // which might trigger an undesired sign-out now or in the future
        if store.state.auth.isAuthenticated {
            Task { [hubLoaderUrl] in
                var hubLoaderUrl = hubLoaderUrl // Capture local copy of var to prevent compiler mutation issues
                _ = try? await Rownd.getAccessToken()
                let rphInit = store.state.auth.toRphInitHash()
                if let rphInit = rphInit {
                    hubLoaderUrl.fragment = "rph_init=\(rphInit)"
                }

                guard let hubLoaderUrl = hubLoaderUrl.url else {
                    return
                }

                Task { @MainActor [self, hubLoaderUrl] in
                    self.hubWebController.setUrl(url: hubLoaderUrl)
                }
            }
        } else {
            guard let hubLoaderUrl = hubLoaderUrl.url else {
                return
            }
            hubWebController.setUrl(url: hubLoaderUrl)
        }

        addChild(hubWebController)
        view.addSubview(hubWebController.view)
        setupConstraints()

        if Rownd.config.forceDarkMode {
            self.overrideUserInterfaceStyle = .dark
        }
    }

    private func initLoadingIndicator(_ parentView: UIView) {
        if let animationView = Rownd.config.customizations.loadingAnimationView {
            customLoadingAnimationView = animationView
        }

        if let customLoadingAnimationView = customLoadingAnimationView {
            parentView.addSubview(customLoadingAnimationView)
        } else {
            activityIndicator.hidesWhenStopped = true
            activityIndicator.translatesAutoresizingMaskIntoConstraints = false
            activityIndicator.startAnimating()
            parentView.addSubview(activityIndicator)
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        handleHostContentWillDisappear()
    }

    func handleHostContentWillDisappear() {
        guard let hostController, hostController.controller === self else {
            self.hostController = nil
            return
        }
        if let presentationRequestID {
            onDismissalStarted?(presentationRequestID)
        }
        guard !isBottomSheetDismissing, !isOuterDismissalScheduled else {
            return
        }

        isOuterDismissalScheduled = true
        DispatchQueue.main.async { [weak self, weak hostController] in
            guard let self, let hostController else { return }
            self.isOuterDismissalScheduled = false
            guard !self.isBottomSheetDismissing else { return }
            guard hostController.controller === self else {
                self.hostController = nil
                return
            }

            self.isBottomSheetDismissing = true
            hostController.dismiss(animated: true) {
                hostController.outerDismissalDidComplete(for: self)
            }
        }
    }

    func setLoading(_ isLoading: Bool) {
        guard let aniView = customLoadingAnimationView else {
            if isLoading {
                activityIndicator.startAnimating()
            } else {
                activityIndicator.stopAnimating()
            }
            return
        }

        if let aniView = aniView as? LottieAnimationView {
            if isLoading {
                aniView.startAnimating()
            } else {
                aniView.stopAnimating()
            }
        } else {
            if !isLoading {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    aniView.removeFromSuperview()
                }
            } else {
                if aniView.superview == nil {
                    view.addSubview(aniView)
                    // Reapply constraints if needed
                }
                aniView.isHidden = false
            }
        }

    }

    func hide() {
        hide(completion: nil)
    }

    func hide(completion: (() -> Void)?) {
        if let completion = completion {
            hideCompletions.append(completion)
        }

        guard let bottomSheetController = hostController else {
            guard presentingViewController != nil else {
                completeHide()
                return
            }
            self.dismiss(animated: true) {
                self.completeHide()
            }
            return
        }

        guard bottomSheetController.controller === self else {
            hostController = nil
            completeHide()
            return
        }

        if let presentationRequestID {
            onDismissalStarted?(presentationRequestID)
        }
        
        if (isBottomSheetDismissing) {
            return
        }
        
        isBottomSheetDismissing = true
        bottomSheetController.hideBottomSheet({
            // UIKit can ignore a presenter dismissal started from its presented
            // controller's dismissal callback while still invoking its completion.
            // Start the outer dismissal on the next run loop. The dismissal
            // completion provides a fallback if viewDidDisappear ran before
            // UIKit fully detached the host.
            DispatchQueue.main.async {
                bottomSheetController.dismiss(animated: true) {
                    bottomSheetController.outerDismissalDidComplete(for: self)
                }
            }
        })
    }

    func hostDidDisappear() {
        completeHide()
        if let presentationRequestID {
            onDisappeared?(presentationRequestID)
        }
    }

    func hostDismissalStarted() {
        if let presentationRequestID {
            onDismissalStarted?(presentationRequestID)
        }
    }

    private func completeHide() {
        isBottomSheetDismissing = false
        isOuterDismissalScheduled = false
        let completions = hideCompletions
        hideCompletions.removeAll()
        completions.forEach { $0() }
    }

    func show() {
        view.isHidden = false
    }

    func updateBottomSheetHeight(_ number: CGFloat) {
        hostController?.updateBottomSheetHeight(number)
    }

    func canTouchDimmingBackgroundToDismiss(_ enable: Bool) {
        hostController?.canTouchDimmingBackgroundToDismiss(enable)
    }

    fileprivate func setupConstraints() {
        hubWebController.view.translatesAutoresizingMaskIntoConstraints = false
        hubWebController.view.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        hubWebController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true
        hubWebController.view.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true
        hubWebController.view.rightAnchor.constraint(equalTo: view.rightAnchor).isActive = true
    }

}
