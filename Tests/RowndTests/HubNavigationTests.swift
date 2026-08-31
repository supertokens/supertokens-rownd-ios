import AnyCodable
import Foundation
import Testing
import WebKit

@testable import Rownd

@Suite(.serialized) struct HubNavigationTests {
    @Test @MainActor func cancelledNavigationDoesNotShowOfflinePage() {
        let controller = HubWebViewController()
        let webView = HubWebViewSpy()

        controller.handleProvisionalNavigationFailure(URLError(.cancelled), in: webView)

        #expect(webView.loadedHTML == nil)
    }

    @Test func loadFailureUsesOnlyFailingHostAndErrorIdentity() throws {
        let failingURL = try #require(URL(string: "https://failed.example.com/private?token=secret#fragment"))
        let configuredURL = try #require(URL(string: "https://configured.example.com/mobile_app?config=secret"))
        let error = NSError(
            domain: "TestNetworkError",
            code: 42,
            userInfo: [
                NSURLErrorFailingURLErrorKey: failingURL,
                NSLocalizedDescriptionKey: "Sensitive localized details"
            ]
        )

        let failure = try #require(HubWebViewController.hubLoadFailure(
            error: error,
            configuredURL: configuredURL
        ))

        #expect(failure == .init(host: "failed.example.com", errorDomain: "TestNetworkError", errorCode: 42))
    }

    @Test func loadFailureUsesFailingURLStringHostBeforeConfiguredHost() throws {
        let configuredURL = try #require(URL(string: "https://configured.example.com/mobile_app"))
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey: "https://string.example.com/private?token=secret#fragment"
            ]
        )

        let failure = try #require(HubWebViewController.hubLoadFailure(
            error: error,
            configuredURL: configuredURL
        ))

        #expect(failure.host == "string.example.com")
    }

    @Test func loadFailureFallsBackToConfiguredHost() throws {
        let configuredURL = try #require(URL(string: "https://configured.example.com/mobile_app"))
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        let failure = try #require(HubWebViewController.hubLoadFailure(
            error: error,
            configuredURL: configuredURL
        ))

        #expect(failure.host == "configured.example.com")
    }

    @Test func cancelledLoadDoesNotProduceFailureEvent() {
        #expect(HubWebViewController.hubLoadFailure(
            error: URLError(.cancelled),
            configuredURL: URL(string: "https://hub.example.com")
        ) == nil)
    }

    @Test func hubRequestUsesURLRequestDefaultTimeout() throws {
        let url = try #require(URL(string: "https://hub.example.com/mobile_app"))

        let request = HubWebViewController.hubRequest(url: url)

        #expect(request.timeoutInterval == URLRequest(url: url).timeoutInterval)
    }

    @Test @MainActor func failureHTMLRendersEscapedDiagnostics() {
        let html = NoInternetHTML(
            appConfig: nil,
            host: #"failed.example.com<script>alert("injected")</script>&"#,
            errorCode: -1200
        )

        #expect(html.contains("Connection failed"))
        #expect(html.contains("<span class=\"diagnostic-label\">Host</span>"))
        #expect(html.contains("<span class=\"diagnostic-value\">failed.example.com&lt;script&gt;alert(&quot;injected&quot;)&lt;/script&gt;&amp;</span>"))
        #expect(html.contains("<span class=\"diagnostic-label\">Error code</span>"))
        #expect(html.contains("<span class=\"diagnostic-value\">-1200</span>"))
        #expect(!html.contains(#"<script>alert("injected")</script>"#))
        #expect(html.contains("Try again"))
    }

    @Test @MainActor func navigationFailureEmitsEventAndRendersDiagnostics() throws {
        try withSynchronousGlobalTestLock {
            let originalContext = Context.currentContext
            _ = Context(createStore())
            defer {
                RowndEventEmitter.resetForTests()
                Context.currentContext = originalContext
            }

            RowndEventEmitter.resetForTests()
            Context.currentContext.eventListeners.removeAll()
            let eventHandler = HubNavigationEventHandler()
            Rownd.addEventHandler(eventHandler)

            let controller = HubWebViewController()
            let webView = HubWebViewSpy()
            controller.setUrl(url: URL(string: "https://configured.example.com/mobile_app")!)
            let error = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCannotFindHost,
                userInfo: [
                    NSURLErrorFailingURLStringErrorKey: "https://failed.example.com/private?token=secret"
                ]
            )

            controller.handleProvisionalNavigationFailure(error, in: webView)

            let event = try #require(eventHandler.events.first)
            #expect(eventHandler.events.map(\.event) == [.hubLoadFailed])
            #expect(event.data?["host"]??.value as? String == "failed.example.com")
            #expect(event.data?["error_domain"]??.value as? String == NSURLErrorDomain)
            #expect(event.data?["error_code"]??.value as? Int == NSURLErrorCannotFindHost)
            #expect(event.data?.count == 3)
            #expect(webView.loadedHTML?.contains("<span class=\"diagnostic-value\">failed.example.com</span>") == true)
            #expect(webView.loadedHTML?.contains("<span class=\"diagnostic-value\">\(NSURLErrorCannotFindHost)</span>") == true)
            #expect(webView.loadedHTML?.contains("token=secret") == false)
        }
    }

    @Test @MainActor func initialURLLoadsExactlyOnceWhenViewLoads() throws {
        let controller = HubWebViewController()
        let webView = HubWebViewSpy()
        controller.webView = webView
        let url = try #require(URL(string: "https://hub.example.com/mobile_app"))

        controller.setUrl(url: url)
        #expect(webView.loadedRequests.isEmpty)

        _ = controller.view

        #expect(webView.loadedRequests.map(\.url) == [url])
    }
}

private final class HubNavigationEventHandler: RowndEventHandlerDelegate {
    private(set) var events: [RowndEvent] = []

    func handleRowndEvent(_ event: RowndEvent) {
        events.append(event)
    }
}

private final class HubWebViewSpy: WKWebView {
    private(set) var loadedRequests: [URLRequest] = []
    private(set) var loadedHTML: String?

    override func load(_ request: URLRequest) -> WKNavigation? {
        loadedRequests.append(request)
        return nil
    }

    override func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        loadedHTML = string
        return nil
    }
}
