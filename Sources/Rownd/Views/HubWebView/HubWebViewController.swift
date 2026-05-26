//
//  WebViewController.swift
//  ios native
//
//  Created by Matt Hamann on 6/14/22.
//

import Foundation
import UIKit
import WebKit
import SwiftUI
import ReSwiftThunk

public enum HubPageSelector {
    case signIn
    case signOut
    case qrCode
    case manageAccount
    case deepLink
    case unknown
}

private final class InputAccessoryHackHelper: NSObject {
    @objc var inputAccessoryView: AnyObject? { return nil }
}

extension WKWebView {
    func hack_removeInputAccessory() {
        guard let target = scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }), let superclass = target.superclass else {
            return
        }

        let noInputAccessoryViewClassName = "\(superclass)_NoInputAccessoryView"
        var newClass: AnyClass? = NSClassFromString(noInputAccessoryViewClassName)

        if newClass == nil, let targetClass = object_getClass(target), let classNameCString = noInputAccessoryViewClassName.cString(using: .ascii) {
            newClass = objc_allocateClassPair(targetClass, classNameCString, 0)

            if let newClass = newClass {
                objc_registerClassPair(newClass)
            }
        }

        guard let noInputAccessoryClass = newClass, let originalMethod = class_getInstanceMethod(InputAccessoryHackHelper.self, #selector(getter: InputAccessoryHackHelper.inputAccessoryView)) else {
            return
        }
        class_addMethod(noInputAccessoryClass.self, #selector(getter: InputAccessoryHackHelper.inputAccessoryView), method_getImplementation(originalMethod), method_getTypeEncoding(originalMethod))
        object_setClass(target, noInputAccessoryClass)
    }
}

public class HubWebViewController: UIViewController, WKUIDelegate {

    let webConfiguration = WKWebViewConfiguration()
    let userController = WKUserContentController()
    lazy var webView: WKWebView = WKWebView(frame: .zero, configuration: webConfiguration)

    var url: URL?
    var hubViewController: HubViewProtocol?
    var jsFunctionArgsAsJson: String = "{}"

    init() {
        super.init(nibName: nil, bundle: nil)

        setup()
    }

    required init?(coder: NSCoder) {
        super.init(nibName: nil, bundle: nil)
        setup()
    }

    private func setup() {
        userController.add(self, name: "rowndIosSDK")
        webConfiguration.userContentController = userController

        // Request mobile view
        let pref = WKWebpagePreferences.init()
        pref.preferredContentMode = .mobile
        webConfiguration.defaultWebpagePreferences = pref

        webView.customUserAgent = Constants.DEFAULT_WEB_USER_AGENT
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
    }

    func setUrl(url: URL) {
        self.url = url
        self.startLoading()
    }

    private func startLoading() {
        guard let url = self.url else { return }

        // Skip loading if already begun
        if webView.isLoading { return }

        var hubRequest = URLRequest(url: url)
        hubRequest.timeoutInterval = 10
        webView.load(hubRequest)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }

    public override func loadView() {
        webView.backgroundColor = UIColor.clear
        webView.scrollView.backgroundColor = UIColor.clear
        webView.hack_removeInputAccessory()
        webView.alpha = 0
        self.modalPresentationStyle = .pageSheet
        view = webView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        startLoading()
    }
}

extension HubWebViewController: WKScriptMessageHandler, WKNavigationDelegate {
    private func evaluateJavaScript(code: String, webView: WKWebView) {
        let wrappedJs = """
            if (typeof rownd !== 'undefined') {
                \(code)
            } else if (typeof window !== 'undefined' && Array.isArray(window._rphConfig)) {
                window._rphConfig.push(['onLoaded', () => {
                    \(code)
                }]);
            }
        """

        logger.trace("Evaluating script: \(code)")

        webView.evaluateJavaScript(wrappedJs) { (result, error) in
            if error == nil {
                logger.trace("JavaScript evaluation finished with result: \(String(describing: result))")
            } else {
                logger.error("Evaluation of '\(code)' failed: \(String(describing: error))")
            }
        }
    }

    private func handleMailToUrl() {
        let gmailUrl = URL(string: "googlegmail://")
        if let gmailUrl = gmailUrl, UIApplication.shared.canOpenURL(gmailUrl) {
            UIApplication.shared.open(gmailUrl, options: [:], completionHandler: nil)
            return
        }

        let outlookUrl = URL(string: "ms-outlook://")
        if let outlookUrl = outlookUrl, UIApplication.shared.canOpenURL(outlookUrl) {
            UIApplication.shared.open(outlookUrl, options: [:], completionHandler: nil)
            return
        }

        let yahooUrl = URL(string: "ymail://")
        if let yahooUrl = yahooUrl, UIApplication.shared.canOpenURL(yahooUrl) {
            UIApplication.shared.open(yahooUrl, options: [:], completionHandler: nil)
            return
        }
        UIApplication.shared.open(URL(string: "message://")!, options: [:], completionHandler: nil)
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let presentableUrls = [
            "https://www.google.com/recaptcha",
            Rownd.config.baseUrl
        ]
        if let url = navigationAction.request.url, !presentableUrls.contains(where: { url.absoluteString.starts(with: $0) == true }), await UIApplication.shared.open(url) {
            return .cancel
        } else {
            return .allow
        }
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            if let url = navigationAction.request.url,
               url.scheme == "mailto" {
                handleMailToUrl()
                decisionHandler(.cancel, preferences)
            } else {
                decisionHandler(.allow, preferences)
            }
    }

    public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // This function is called whenever the Webview attempts to navigate to a different url
        if navigationAction.targetFrame == nil {
            let url = navigationAction.request.url
            if UIApplication.shared.canOpenURL(url!) {
                if url?.absoluteString != "mailto:" {
                    UIApplication.shared.open(url!, options: [:], completionHandler: nil)
                    return nil
                }
                handleMailToUrl()
                return nil
            }
        }
        return nil
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation) {
        // This function is called when the webview finishes navigating to the webpage.
        // We use this to send data to the webview when it's loaded.

        webViewOnLoad(webView: webView, targetPage: nil, jsFnOptions: nil)
    }

    public func webViewOnLoad(webView: WKWebView, targetPage: HubPageSelector?, jsFnOptions: Encodable?) {
        Task { @MainActor in
            webView.isOpaque = false
            webView.backgroundColor = UIColor.clear
            webView.scrollView.backgroundColor = UIColor.clear

            guard webView.url?.absoluteString.starts(with: Rownd.config.baseUrl) == true else {
                self.animateInContent()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                self.animateInContent()
            }

            self.setFeatureFlagsJS()

            if let jsFnOptions = jsFnOptions {
                do {
                    self.jsFunctionArgsAsJson = try jsFnOptions.asJsonString()
                } catch {
                    logger.error("Failed to encode JS options to pass to function: \(String(describing: error))")
                }
            }

            switch targetPage ?? self.hubViewController?.targetPage {
            case .signOut:
                self.evaluateJavaScript(code: "rownd.signOut({\"show_success\":true})", webView: webView)
            case .signIn, .unknown:
                self.evaluateJavaScript(code: "rownd.requestSignIn(\(self.jsFunctionArgsAsJson))", webView: webView)
            case .qrCode:
                self.evaluateJavaScript(code: "rownd.generateQrCode(\(self.jsFunctionArgsAsJson))", webView: webView)
            case .manageAccount:
                self.evaluateJavaScript(code: "rownd.user.manageAccount()", webView: webView)
            case .deepLink:
                break
            case .none:
                return
            }
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation, withError error: Error) {
        let store = Context.currentContext.store
        webView.loadHTMLString(NoInternetHTML(appConfig: store.state.appConfig), baseURL: nil)
    }

    private func setFeatureFlagsJS() {
        let frameworkFeaturesString = String(describing: getFrameworkFeatures())
        let code = """
            if (typeof rownd !== 'undefined' && rownd.setSessionStorage) {
                rownd.setSessionStorage("rph_feature_flags", `\(frameworkFeaturesString)`)
            }
        """
        evaluateJavaScript(code: code, webView: webView)
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // This function handles the events coming from javascript. We'll configure the javascript side of this later.
        // We can access properties through the message body, like this:
        guard let response = message.body as? String else { return }

        logger.trace("Received message from hub: \(Redact.redactSensitiveKeys(in: response))")

        let store = Context.currentContext.store

        do {
            let hubMessage = try RowndHubInteropMessage.fromJson(message: response)

            logger.debug("Received message from hub with type: \(String(describing: hubMessage.type))")

            switch hubMessage.type {
            case .authentication:
                guard case .authentication(let authMessage) = hubMessage.payload else { return }
                guard hubViewController?.targetPage == .signIn  else { return }
                let initialJsFunctionArgsAsJson = self.jsFunctionArgsAsJson

                Task.detached(priority: .userInitiated) { [weak self] in
                    SuperTokensSessionBridge.bootstrapSession(
                        accessToken: authMessage.accessToken,
                        refreshToken: authMessage.refreshToken,
                        frontToken: authMessage.frontToken,
                        antiCSRF: authMessage.antiCSRF
                    )
                    await SuperTokensSessionBridge.syncRowndAuthStateFromSuperTokens()

                    await MainActor.run {
                        // Ensure user.isLoading = false so that the data is fetched properly
                        store.dispatch(SetUserLoading(isLoading: false))
                        store.dispatch(UserData.fetch())
                        store.dispatch(ResetSignInState())
                    }

                    await MainActor.run { [weak self] in
                        // Close the hub as long as no other rownd api was called
                        if initialJsFunctionArgsAsJson == self?.jsFunctionArgsAsJson {
                            self?.hubViewController?.hide()
                        }
                    }
                }
            case .closeHubViewController:
                DispatchQueue.main.async {
                    self.hubViewController?.hide()
                }
            case .userDataUpdate:
                guard case .userDataUpdate(let userDataMessage) = hubMessage.payload else { return }
                guard hubViewController?.targetPage == .manageAccount else { return }
                DispatchQueue.main.async {
                    store
                        .dispatch(
                            SetUserState(payload: userDataMessage.toUserState())
                        )
                }

            case .triggerSignInWithApple:
                var signInWithAppleMessage: MessagePayload.TriggerSignInWithAppleMessage?
                if case .triggerSignInWithApple(let message) = hubMessage.payload {
                    signInWithAppleMessage = message
                }
                //                self.hubViewController?.hide()
                Rownd.requestSignIn(
                    with: .appleId,
                    signInOptions: RowndSignInOptions(
                        intent: signInWithAppleMessage?.intent
                    )
                )

            case .triggerSignInWithGoogle:
                var signInWithGoogleMessage: MessagePayload.TriggerSignInWithGoogleMessage?
                if case .triggerSignInWithGoogle(let message) = hubMessage.payload {
                    signInWithGoogleMessage = message
                }
                Rownd.requestSignIn(with: RowndSignInHint.googleId, signInOptions: RowndSignInOptions(intent: signInWithGoogleMessage?.intent, hint: signInWithGoogleMessage?.hint))

            case .signOut:
                // Occasionally, the hub may send a sign-out message due to expired token
                // or possible race condition. This check prevents accidental sign-outs
                // from occurring
                var signOutMessage: MessagePayload.SignOutMessage?
                if case .signOut(let message) = hubMessage.payload {
                    signOutMessage = message
                }

                if hubViewController?.targetPage != .signOut &&
                    signOutMessage?.wasUserInitiated != true {
                    return;
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in // .now() + num_seconds
                    self?.hubViewController?.hide()
                }
                Rownd.signOut()
            case .tryAgain:
                startLoading()
            case .hubLoaded:
                self.animateInContent()

            case .hubResize:
                guard case .hubResize(let hubResizeMessage) = hubMessage.payload else { return }
                if let doubleValue = Double(hubResizeMessage.height ?? "") {
                    let cgFloatValue = CGFloat(doubleValue)
                    self.hubViewController?.updateBottomSheetHeight(cgFloatValue)
                } else {
                    logger.error("Invalid string format for Hub Resize.")
                }

            case .canTouchBackgroundToDismiss:
                guard case .canTouchBackgroundToDismiss(let canDismissMessage) = hubMessage.payload else { return }
                if canDismissMessage.enable == "false" {
                    self.hubViewController?.canTouchDimmingBackgroundToDismiss(false)
                    return
                }
                self.hubViewController?.canTouchDimmingBackgroundToDismiss(true)
                break
            case .event:
                guard case .event(let eventMessage) = hubMessage.payload else { return }
                RowndEventEmitter.emit(eventMessage)
                break
            case .unknown:
                break
            case .authChallengeInitiated:
                guard case .authChallengeInitiated(let authChallengeMessage) = hubMessage.payload else { return }
                DispatchQueue.main.async {
                    var newAuthState = Context.currentContext.store.state.auth
                    newAuthState.challengeId = authChallengeMessage.challengeId
                    newAuthState.userIdentifier = authChallengeMessage.userIdentifier
                    Context.currentContext.store.dispatch(
                        SetAuthState(payload: newAuthState)
                    )
                }
                break
            case .authChallengeCleared:
                DispatchQueue.main.async {
                    var newAuthState = Context.currentContext.store.state.auth
                    newAuthState.challengeId = nil
                    newAuthState.userIdentifier = nil

                    Context.currentContext.store.dispatch(
                        SetAuthState(payload: newAuthState)
                    )
                }
                break;
            }
        } catch {
            logger.debug("Failed to decode incoming interop message: \(String(describing: error))")
        }
    }

    private func animateInContent() {
        UIView.animate(withDuration: 1.0) {
            self.webView.alpha = 1.0
            self.hubViewController?.setLoading(false)
        }
    }
}
