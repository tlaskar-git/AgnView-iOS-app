import XCTest

final class AgnViewUITests: XCTestCase {
    private var app: XCUIApplication!
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    private var device: String { isPad ? "ipad" : "iphone" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Dismiss system alerts such as the camera permission prompt so they
        // never cover the screenshots.
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

    /// Launches the app. `mock` pairs the mock hub over LAN. `state` forces a
    /// connection state without a hub. With neither, the app starts unpaired.
    private func launch(mock: Bool = false, state: String? = nil) {
        app = XCUIApplication()
        if mock {
            let hub = ProcessInfo.processInfo.environment["AGNVIEW_MOCK_HUB_URL"] ?? "http://127.0.0.1:18081"
            app.launchEnvironment["AGNVIEW_MOCK_HUB_URL"] = hub
        }
        if let state {
            app.launchEnvironment["AGNVIEW_FORCE_STATE"] = state
        }
        app.launch()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func need(_ id: String, timeout: TimeInterval = 20) {
        XCTAssertTrue(element(id).waitForExistence(timeout: timeout), "\(id) missing")
    }

    /// Closes a system alert (such as the camera permission prompt) that is
    /// still on screen, because the interruption monitor only runs on a tap.
    private func dismissSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        for label in ["Don\u{2019}t Allow", "Don't Allow", "Not Now", "Cancel", "OK", "Allow"] {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                break
            }
        }
        Thread.sleep(forTimeInterval: 1)
    }

    private func snap(_ name: String) {
        dismissSystemAlert()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(device)-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func hittable(_ id: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let query = app.descendants(matching: .any).matching(identifier: id)
            for element in query.allElementsBoundByIndex where element.isHittable {
                return element
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return nil
    }

    private func tapNav(_ name: String) {
        if isPad {
            // The identifier is shared by the cell and its children, so pick a hittable match.
            let id = "nav-" + name.lowercased()
            var row = hittable(id, timeout: 5)
            if row == nil {
                // Sidebar hidden in this orientation: reveal it.
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
    private func open(_ name: String) {
        let id = "screen-" + name.lowercased()
        tapNav(name)
        if !element(id).waitForExistence(timeout: 8) {
            tapNav(name)
        }
        need(id)
    }

    // MARK: Against the mock hub

    func testScreensWithMockHub() throws {
        launch(mock: true)
        for name in ["Console", "Sessions", "Pipelines", "Usage", "Settings"] {
            let key = name.lowercased()
            open(name)
            need("route-pill")
            if key == "console" {
                let line = element("status-line")
                need("status-line")
                let healthy = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label CONTAINS 'healthy'"), object: line)
                XCTAssertEqual(XCTWaiter().wait(for: [healthy], timeout: 20), .completed,
                               "status line never showed the healthy mock hub")
            }
            if key == "usage" {
                need("provider-claude")
            }
            snap(key)
        }
    }

    func testSettingsMachineList() throws {
        launch(mock: true)
        open("Settings")
        need("machine-row")
        need("add-machine")
        need("appearance-picker")
        snap("state-settings-machines")
    }

    // MARK: Forced states

    func testOffLANConsoleComposer() throws {
        launch(state: "iroh")
        open("Console")
        need("banner-not-on-network")
        need("composer-notice")
        need("console-log")
        snap("state-composer-disabled")
    }

    func testOffLANUsage() throws {
        launch(state: "iroh")
        open("Usage")
        need("usage-notice")
        need("provider-claude")
        need("usage-age")
        snap("state-usage-offlan")
    }

    func testOffLANPipelines() throws {
        launch(state: "iroh")
        open("Pipelines")
        need("pipelines-notice")
        snap("state-pipelines-offlan")
    }

    func testOffLANSessions() throws {
        launch(state: "iroh")
        open("Sessions")
        need("sessions-notice")
        snap("state-sessions-offlan")
    }

    func testOfflineState() throws {
        launch(state: "offline")
        need("state-offline")
        snap("state-offline")
        leaveThroughSettings("state-offline")
    }

    func testAuthFailedState() throws {
        launch(state: "authFailed")
        need("state-authFailed")
        snap("state-authFailed")
        leaveThroughSettings("state-authFailed")
    }

    func testKeyRevokedState() throws {
        launch(state: "keyRevoked")
        need("state-keyRevoked")
        snap("state-keyRevoked")
        leaveThroughSettings("state-keyRevoked")
    }

    /// A full-screen state never traps the user: the Switch machine button and
    /// the tab bar both reach Settings, where the machines can be changed.
    private func leaveThroughSettings(_ state: String) {
        let button = element(state + "-settings")
        need(state + "-settings")
        button.tap()
        need("screen-settings")
        need("machine-row")
        need("add-machine")
        open("Console")
        need(state)
        open("Settings")
        need("machine-row")
    }

    /// The composer sends against the mock hub and shows the reply inline.
    func testComposerSendsAndClosesTheKeyboard() throws {
        launch(mock: true)
        open("Console")
        let prompt = element("composer-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 30))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                object: prompt)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed)
        prompt.tap()
        prompt.typeText("Example prompt")
        element("composer-send").tap()
        need("composer-result", timeout: 30)
        let done = element("keyboard-done")
        if done.waitForExistence(timeout: 5) {
            done.tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                   object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 10), .completed)
        }
    }

    func testRelayOnlyState() throws {
        launch(state: "relayOnly")
        need("banner-relay-only")
        need("banner-scan-again")
        snap("state-relayOnly")
    }

    // MARK: Pairing

    func testOnboardingAndPairingSheet() throws {
        launch()
        need("state-onboarding")
        snap("state-onboarding")
        let scan = element("state-onboarding-primary")
        need("state-onboarding-primary")
        scan.tap()
        need("pairing-scan")
        need("scanner-paste-field")
        snap("state-pairing-sheet")
    }
}
