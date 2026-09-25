import XCTest

/// End-to-end tests against a real AgnView hub. Only the e2e-lan workflow runs
/// them: it starts the hub and sets TEST_RUNNER_AGNVIEW_E2E=1. Every other run
/// skips them. The hub address, the key and the fault proxy address come from
/// the test environment. The key is passed to the app and never printed.
final class AgnViewE2ETests: XCTestCase {
    private var app: XCUIApplication!
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(env["AGNVIEW_E2E"] == "1", "Real-hub tests run in the e2e-lan workflow only")
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for label in ["Don\u{2019}t Allow", "Don't Allow", "Not Now", "Cancel", "OK", "Allow"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: Helpers

    private func launch(hubKey: String) throws {
        let hub = try XCTUnwrap(env[hubKey], "\(hubKey) is not set")
        let key = try XCTUnwrap(env["AGNVIEW_E2E_KEY"], "AGNVIEW_E2E_KEY is not set")
        app = XCUIApplication()
        app.launchEnvironment["AGNVIEW_MOCK_HUB_URL"] = hub
        app.launchEnvironment["AGNVIEW_E2E_KEY"] = key
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func need(_ id: String, timeout: TimeInterval = 30) {
        XCTAssertTrue(element(id).waitForExistence(timeout: timeout), "\(id) missing")
    }

    private func gone(_ id: String, timeout: TimeInterval = 10) -> Bool {
        let missing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                object: element(id))
        return XCTWaiter().wait(for: [missing], timeout: timeout) == .completed
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "e2e-\(isPad ? "ipad" : "iphone")-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func hittable(_ id: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let query = app.descendants(matching: .any).matching(identifier: id)
            for item in query.allElementsBoundByIndex where item.isHittable { return item }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    private func tapNav(_ name: String) {
        if isPad {
            let id = "nav-" + name.lowercased()
            var row = hittable(id, timeout: 5)
            if row == nil {
                let toggle = app.navigationBars.buttons.firstMatch
                if toggle.waitForExistence(timeout: 5) { toggle.tap() }
                row = hittable(id, timeout: 20)
            }
            XCTAssertNotNil(row, "sidebar item \(name) missing")
            row?.tap()
        } else {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 20), "tab \(name) missing")
            tab.tap()
        }
    }

    private func open(_ name: String) {
        let id = "screen-" + name.lowercased()
        tapNav(name)
        if !element(id).waitForExistence(timeout: 8) { tapNav(name) }
        need(id)
    }

    /// Waits until the console is online and the composer accepts input.
    private func waitForComposer() {
        open("Console")
        let prompt = element("composer-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 40), "composer missing")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                object: prompt)
        let result = XCTWaiter().wait(for: [enabled], timeout: 40)
        if result != .completed {
            snap("failure-composer-disabled")
            let pill = element("route-pill").label
            let status = element("status-line").exists ? element("status-line").label : "none"
            let notice = element("composer-notice").exists ? element("composer-notice").label : "none"
            XCTFail("composer never became enabled. route: \(pill). status: \(status). notice: \(notice)")
        }
    }

    private func typePrompt(_ text: String) {
        let prompt = element("composer-prompt")
        prompt.tap()
        prompt.typeText(text)
    }

    private func sendPromptAndSeeReply(_ text: String) {
        typePrompt(text)
        let send = element("composer-send")
        XCTAssertTrue(send.isEnabled, "Send stayed disabled with text in the field")
        send.tap()
        need("composer-result", timeout: 40)
        let reply = element("composer-result").label
        XCTAssertTrue(reply.contains("Agent:"), "reply lacks the agent: \(reply)")
        XCTAssertFalse(reply.contains("does not understand"), "reply shows a decode error: \(reply)")
    }

    // MARK: Tests

    /// Send, reply, keyboard dismissal and every tab against the real hub.
    func testSendKeyboardAndTabsAgainstRealHub() throws {
        try launch(hubKey: "AGNVIEW_MOCK_HUB_URL")
        waitForComposer()
        let status = element("status-line")
        need("status-line")
        let connected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH 'Connected'"), object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [connected], timeout: 40), .completed,
                       "status line never showed the hub status")
        snap("console-connected")

        typePrompt("hello from the end to end run")
        snap("console-typing")
        let send = element("composer-send")
        XCTAssertTrue(send.isEnabled)
        send.tap()
        need("composer-result", timeout: 40)
        XCTAssertTrue(element("composer-result").label.contains("Agent:"))
        let fieldValue = (element("composer-prompt").value as? String) ?? ""
        XCTAssertTrue(fieldValue.isEmpty || fieldValue == "Prompt",
                      "the field was not cleared after a successful send")
        snap("console-after-send")

        // The keyboard must close with Done.
        let prompt = element("composer-prompt")
        prompt.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard never appeared")
        let done = element("keyboard-done")
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the keyboard has no Done button")
        snap("keyboard-open")
        done.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 10), .completed, "the keyboard stayed open after Done")
        snap("keyboard-dismissed")

        for name in ["Sessions", "Pipelines", "Usage", "Settings", "Console"] {
            open(name)
            snap("tab-" + name.lowercased())
        }

        open("Pipelines")
        let job = element("job-row")
        XCTAssertTrue(job.waitForExistence(timeout: 30) || element("pipelines-empty").exists,
                      "Pipelines showed neither a job nor an empty state")
        open("Usage")
        let usageShown = element("provider-claude").waitForExistence(timeout: 30)
            || element("usage-empty").waitForExistence(timeout: 5)
        XCTAssertTrue(usageShown, "Usage showed neither a card nor an empty state")
        XCTAssertFalse(element("usage-error").exists, "the real hub made Usage fail")
    }

    /// A malformed answer for one request fails that panel only.
    func testUsageErrorStaysInItsPanel() throws {
        try launch(hubKey: "AGNVIEW_E2E_PROXY_URL")
        waitForComposer()

        open("Usage")
        need("usage-error", timeout: 40)
        need("usage-retry")
        XCTAssertTrue(element("usage-error").label.contains("Usage could not be read"))
        snap("usage-error")

        // Retry keeps the error while the proxy keeps failing, and nothing else moves.
        element("usage-retry").tap()
        need("usage-error", timeout: 20)
        need("route-pill")

        for name in ["Sessions", "Pipelines", "Settings"] {
            open(name)
            XCTAssertFalse(element("usage-error").exists, "the Usage error leaked into \(name)")
            snap("tab-" + name.lowercased() + "-with-usage-error")
        }
        need("machine-row")

        open("Console")
        XCTAssertFalse(element("state-offline").exists)
        XCTAssertFalse(element("state-authFailed").exists)
        waitForComposer()
        sendPromptAndSeeReply("still works with a failed usage panel")
        snap("console-send-with-usage-error")

        let done = element("keyboard-done")
        if done.exists { done.tap() }
        open("Usage")
        need("usage-error")
    }
}
