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
    func updateBottomSheetHeight(_ height: CGFloat)
    func canTouchDimmingBackgroundToDismiss(_ enable: Bool)
}

public class HubViewController: UIViewController, HubViewProtocol, BottomSheetHostProtocol {
    @objc var preferredHeightInBottomSheet: CGFloat = UIScreen.main.bounds.height * 0.3
    var activityIndicator = UIActivityIndicatorView(style: .large)
    var customLoadingAnimationView: UIView?
    var hubWebController = HubWebViewController()
    var targetPage = HubPageSelector.unknown
    var hostController: BottomSheetViewController?
    var isBottomSheetDismissing: Bool = false

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
        ]

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

    public func loadNewPage(targetPage: HubPageSelector, jsFnOptions: Encodable?) {
        DispatchQueue.main.async {
            self.targetPage = targetPage
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
    }

    public override func loadView() {
        hubWebController.hubViewController = self

        let base64EncodedConfig = Rownd.config.toJson()
            .data(using: .utf8)?
            .base64EncodedString(options: Data.Base64EncodingOptions(rawValue: 0)) ?? ""

        let store = Context.currentContext.store
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
        guard let hostController = hostController else {
            return
        }

        hostController.dismiss(animated: true)
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
        guard let bottomSheetController = hostController else {
            self.dismiss(animated: true)
            return
        }
        
        if (isBottomSheetDismissing) {
            return
        }
        
        isBottomSheetDismissing = true
        bottomSheetController.hideBottomSheet({
            self.dismiss(animated: true)
            self.isBottomSheetDismissing = false
        })
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
