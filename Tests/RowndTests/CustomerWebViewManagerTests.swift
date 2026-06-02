//
//  CustomerWebViewManagerTests.swift
//  Rownd
//
//  Created by Bobby on 4/14/25.
//

import Testing
import WebKit
@testable import Rownd

@Suite(.serialized) struct CustomerWebViewManagerTests {
    /// Register a customer web view and ensure that message handling and script evaluation work correctly
    @Test func registerTest() async throws {
        let messageHandler = ScriptMessageHandlerSpy()

        let manager = CustomerWebViewManager(wkScriptMessageHandlerProvider: { customerWebViewId in
            return messageHandler
        })
        let wv = await WKWebView()
        let deregister = manager.register(wv)
        
        #expect(manager.webViews.count == 1)
        #expect(manager.webView(id: manager.webViews[0].id) == wv)
        
        try await wv.evaluateJavaScript("""
            var _rphConfig = _rphConfig || [];
            _rphConfig.push(["onLoaded", () => { console.log("loaded"); }]);
        """)
         
        messageHandler.userContentController(WKUserContentController(), didReceive: MockScriptMessage(body: "{}"))
        #expect(messageHandler.didReceiveCallCount == 1)

        deregister()
        #expect(manager.webViews.count == 0)
        messageHandler.reset()
         
        try await wv.evaluateJavaScript("""
            var _rphConfig = _rphConfig || [];
            _rphConfig.push(["onLoaded", () => { console.log("loaded"); }]);
        """)

        #expect(messageHandler.didReceiveCallCount == 0)
    }
}

private final class ScriptMessageHandlerSpy: NSObject, WKScriptMessageHandler {
    private(set) var didReceiveCallCount = 0

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        didReceiveCallCount += 1
    }

    func reset() {
        didReceiveCallCount = 0
    }
}

private final class MockScriptMessage: WKScriptMessage {
    private let mockedBody: Any

    init(body: Any) {
        self.mockedBody = body
        super.init()
    }

    override var body: Any {
        mockedBody
    }
}
