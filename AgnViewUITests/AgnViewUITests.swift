import XCTest

final class AgnViewUITests: XCTestCase {
    private var app: XCUIApplication!
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    private var device: String { isPad ? "ipad" : "iphone" }

    override func setUpWithError() throws {
        continueAfterFailure = false
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

    private func snap(_ name: String) {
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
    }

    func testAuthFailedState() throws {
        launch(state: "authFailed")
        need("state-authFailed")
        snap("state-authFailed")
    }

    func testKeyRevokedState() throws {
        launch(state: "keyRevoked")
        need("state-keyRevoked")
        snap("state-keyRevoked")
    }

    func testRelayOnlyState() throws {
        launch(state: "relayOnly")
        need("banner-relay-only")
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
