import XCTest

/// Shared helpers for the tests that run in demo mode. The app starts with no
/// machine paired, and the test taps Try the demo, as a reviewer would.
class DemoUITestCase: XCTestCase {
    var app: XCUIApplication!
    let isPad = UIDevice.current.userInterfaceIdiom == .pad

    override func setUpWithError() throws {
        continueAfterFailure = false
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

    /// Launches with no machine paired. `appearance` is light, dark or system.
    func launchUnpaired(appearance: String = "light") {
        app = XCUIApplication()
        app.launchArguments += ["-appearance", appearance]
        app.launch()
    }

    /// Launches unpaired and starts the demo from the onboarding screen.
    func startDemoFromOnboarding(appearance: String = "light") {
        launchUnpaired(appearance: appearance)
        need("state-onboarding", timeout: 30)
        need("state-onboarding-demo")
        element("state-onboarding-demo").tap()
        need("demo-banner", timeout: 30)
    }

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    func need(_ id: String, timeout: TimeInterval = 20) {
        XCTAssertTrue(element(id).waitForExistence(timeout: timeout), "\(id) missing")
    }

    func hittable(_ id: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let query = app.descendants(matching: .any).matching(identifier: id)
            for candidate in query.allElementsBoundByIndex where candidate.isHittable {
                return candidate
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    /// Finds an element in a list, scrolling down and then up until it exists.
    func findAnywhere(_ id: String, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element(id).waitForExistence(timeout: 3) { return true }
            for _ in 0..<8 where !element(id).exists { app.swipeUp() }
            if element(id).exists { return true }
            for _ in 0..<8 where !element(id).exists { app.swipeDown() }
        } while Date() < deadline && !element(id).exists
        return element(id).exists
    }

    func needAnywhere(_ id: String, timeout: TimeInterval = 20) {
        XCTAssertTrue(findAnywhere(id, timeout: timeout), "\(id) missing")
    }

    /// An item of the menu that is open. Picker items show as buttons on some
    /// systems and as menu items on others.
    func menuOption(_ name: String, timeout: TimeInterval = 10) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.buttons[name].exists { return app.buttons[name] }
            if app.menuItems[name].exists { return app.menuItems[name] }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return app.buttons[name]
    }

    func tapNav(_ name: String) {
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

    /// Opens a screen and waits for its root. Retries the tap once.
    func open(_ name: String) {
        let id = "screen-" + name.lowercased()
        tapNav(name)
        if !element(id).waitForExistence(timeout: 8) {
            tapNav(name)
        }
        need(id)
    }

    /// Waits until the prompt field accepts input, which needs the demo connection.
    func waitForComposer() {
        let prompt = element("composer-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 30))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                object: prompt)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed)
    }

    /// Closes the keyboard when it is open.
    func closeKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let done = element("keyboard-done")
        if done.exists { done.tap() } else { element("console-log").tap() }
    }

    /// Types a prompt and sends it. The demo answers with a built-in reply.
    func sendPrompt(_ text: String) {
        waitForComposer()
        let prompt = element("composer-prompt")
        prompt.tap()
        prompt.typeText(text)
        element("composer-send").tap()
        need("composer-result", timeout: 30)
    }

    /// True when a console row with this text exists.
    func consoleHas(_ text: String, timeout: TimeInterval = 20) -> Bool {
        let row = app.descendants(matching: .any)
            .matching(identifier: "console-row")
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        return row.waitForExistence(timeout: timeout)
    }
}
