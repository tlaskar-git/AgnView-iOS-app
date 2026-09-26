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
    /// `appearance` is system, light or dark.
    private func launch(mock: Bool = false, state: String? = nil, appearance: String? = nil) {
        app = XCUIApplication()
        if let appearance {
            // The app reads its appearance choice from the "appearance" default.
            app.launchArguments += ["-appearance", appearance]
        }
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

    /// An item of the menu that is open. Picker items in a menu show as
    /// buttons on some systems and as menu items on others.
    private func menuOption(_ name: String, timeout: TimeInterval = 10) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.buttons[name].exists { return app.buttons[name] }
            if app.menuItems[name].exists { return app.menuItems[name] }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return app.buttons[name]
    }

    /// Opens the agent menu in the composer and picks one agent.
    private func chooseAgent(_ id: String, name: String) {
        need("composer-agent")
        element("composer-agent").tap()
        let byId = element("composer-agent-option-" + id)
        if byId.waitForExistence(timeout: 5) {
            byId.tap()
            return
        }
        let byName = menuOption(name)
        XCTAssertTrue(byName.exists, "the agent menu never offered \(name)")
        byName.tap()
    }

    /// Finds an element in a list. A list builds only the rows near the
    /// screen, so this scrolls down and then back up until the element exists.
    private func findAnywhere(_ id: String, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element(id).waitForExistence(timeout: 3) { return true }
            for _ in 0..<8 where !element(id).exists { app.swipeUp() }
            if element(id).exists { return true }
            for _ in 0..<8 where !element(id).exists { app.swipeDown() }
        } while Date() < deadline && !element(id).exists
        return element(id).exists
    }

    private func needAnywhere(_ id: String, timeout: TimeInterval = 20) {
        XCTAssertTrue(findAnywhere(id, timeout: timeout), "\(id) missing")
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
                needAnywhere("provider-claude")
            }
            snap(key)
        }
    }

    func testSettingsMachineList() throws {
        launch(mock: true)
        open("Settings")
        need("machine-row")
        need("add-machine")
        needAnywhere("appearance-picker")
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
        needAnywhere("provider-claude")
        needAnywhere("usage-age")
        snap("state-usage-offlan")
    }

    func testOffLANPipelines() throws {
        launch(state: "iroh")
        open("Pipelines")
        need("pipelines-notice")
        snap("state-pipelines-offlan")
    }

    /// Over iroh to a hub 0.1.13 or later: plus opens the New pipeline sheet
    /// and no screen asks for the same Wi-Fi.
    func testIrohPipelineCreateOnANewerHub() throws {
        launch(state: "irohJobs")
        open("Pipelines")
        let plus = element("pipelines-new")
        need("pipelines-new")
        XCTAssertTrue(plus.isEnabled, "New pipeline is on over iroh with a newer hub")
        XCTAssertFalse(element("pipelines-notice").exists)
        XCTAssertFalse(element("pipelines-create-notice").exists)
        plus.tap()
        need("new-pipeline")
        need("np-title")
        XCTAssertFalse(element("np-notice").exists, "the sheet shows no Wi-Fi notice")
        let wifi = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Wi-Fi'")).firstMatch
        XCTAssertFalse(wifi.exists, "no text asks for the same Wi-Fi")
        XCTAssertTrue(element("np-create").isEnabled, "Create is on over iroh with a newer hub")
        snap("state-iroh-new-pipeline")
    }

    /// Over iroh the Model menu lists the models kept from the LAN.
    func testIrohModelMenuShowsTheKeptList() throws {
        launch(state: "irohJobs")
        open("Console")
        need("composer-model")
        element("composer-model").tap()
        let large = menuOption("Example Large")
        XCTAssertTrue(large.exists, "the kept model list never reached the menu")
        XCTAssertTrue(menuOption("Example Small", timeout: 3).exists)
        snap("state-iroh-model-menu")
        large.tap()
        XCTAssertEqual(element("composer-model").value as? String, "Example Large")
        chooseAgent("codex", name: "Codex")
        element("composer-model").tap()
        XCTAssertTrue(menuOption("Example Codex").exists, "the Codex list is missing")
        XCTAssertTrue(menuOption("Example Mini", timeout: 3).exists)
        snap("state-iroh-model-menu-codex")
        menuOption("Example Mini").tap()
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

    /// The keyboard toolbar carries Model and Effort on the left and Done on the
    /// right, and nothing in it sits over Send.
    func testKeyboardToolbarHasChipsAndDoesNotCoverSend() throws {
        launch(mock: true)
        open("Console")
        let prompt = element("composer-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 30))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                object: prompt)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed)
        need("composer-model")
        need("composer-effort")
        need("composer-attach")
        prompt.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard never appeared")
        if !isPad {
            need("toolbar-model", timeout: 10)
            need("toolbar-effort", timeout: 10)
            need("keyboard-done", timeout: 10)
            let done = element("keyboard-done").frame
            let send = element("composer-send").frame
            XCTAssertFalse(done.intersects(send), "Done sits over Send")
        }
        snap("console-keyboard")
        let done = element("keyboard-done")
        if done.waitForExistence(timeout: 5) { done.tap() }
    }

    /// Model and Effort come from the hub and show on their chips.
    func testModelAndEffortMenusUseTheHubLists() throws {
        launch(mock: true)
        open("Console")
        let prompt = element("composer-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 30))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                object: prompt)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed)
        // The lists arrive a moment after the connection. Open the menu again until they are in.
        var picked = false
        for _ in 0..<6 where !picked {
            element("composer-model").tap()
            let large = menuOption("Example Large", timeout: 5)
            if large.exists {
                large.tap()
                picked = true
            } else {
                // Close the menu with a tap on the empty log area, then wait and retry.
                element("console-log").tap()
                Thread.sleep(forTimeInterval: 2)
            }
        }
        XCTAssertTrue(picked, "the hub model list never reached the menu")
        element("composer-effort").tap()
        let low = menuOption("Low Effort")
        XCTAssertTrue(low.exists, "the hub effort list never reached the menu")
        low.tap()
        XCTAssertTrue(element("composer-model").label.contains("Model"))
        XCTAssertEqual(element("composer-effort").value as? String, "Low")
    }

    /// Pipelines: plus opens the sheet, validation blocks an empty form, the
    /// attach picker draws the disabled phone sources, and a created pipeline opens.
    func testNewPipelineFlowAgainstMockHub() throws {
        launch(mock: true)
        open("Pipelines")
        need("job-row", timeout: 30)
        let plus = element("pipelines-new")
        need("pipelines-new")
        XCTAssertTrue(plus.isEnabled, "New pipeline stays disabled on the LAN")
        plus.tap()
        need("new-pipeline")
        need("np-title")
        // An empty form does not send. It shows what is missing.
        element("np-create").tap()
        need("np-issues")
        XCTAssertTrue(element("np-issues").label.contains("Title is required"))

        let title = element("np-title")
        title.tap()
        title.typeText("Example release")
        let taskTitle = element("np-task-title")
        taskTitle.tap()
        taskTitle.typeText("Build it")
        let done = element("np-keyboard-done")
        if done.waitForExistence(timeout: 3) { done.tap() }

        element("np-attach").tap()
        need("attach-sheet")
        need("attach-source-files")
        need("attach-source-photos")
        XCTAssertFalse(element("attach-source-files").isEnabled, "the phone source must be disabled in phase A")
        XCTAssertFalse(element("attach-source-photos").isEnabled, "the phone source must be disabled in phase A")
        let needsUpdate = app.staticTexts["Needs AgnView 0.1.13 on your computer"]
        XCTAssertTrue(needsUpdate.waitForExistence(timeout: 5), "the disabled source has no reason")
        need("attach-file-row", timeout: 30)
        snap("attach-sheet")
        element("attach-file-row").tap()
        element("attach-confirm").tap()
        need("np-attachment")
        snap("new-pipeline")

        element("np-create").tap()
        need("job-detail", timeout: 30)
        XCTAssertEqual(element("job-detail-title").label, "Example release")
        let row = element("task-row")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("[Context Files:"), "the attached file is not in the task description")
    }

    func testSessionsRefreshShowsUpdated() throws {
        launch(mock: true)
        open("Sessions")
        need("sessions-refresh")
        element("sessions-refresh").tap()
        need("sessions-updated")
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Updated'"),
                                                object: element("sessions-updated"))
        XCTAssertEqual(XCTWaiter().wait(for: [updated], timeout: 20), .completed,
                       "Sessions never showed when it was updated")
        snap("sessions-refresh")
    }

    /// Usage draws the hub's windows and says "Not measured yet" only where the hub returned null.
    func testUsageShowsWindowsFromTheHub() throws {
        launch(mock: true)
        open("Usage")
        needAnywhere("provider-antigravity", timeout: 40)
        need("usage-refresh")
        needAnywhere("usage-window")
        needAnywhere("usage-breakdown")
        needAnywhere("usage-source")
        let five = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Five Hour Limit'")).firstMatch
        if !five.exists { _ = findAnywhere("usage-window") }
        XCTAssertTrue(five.waitForExistence(timeout: 10))
        XCTAssertTrue(five.label.contains("91% used"))
        element("usage-refresh").tap()
        needAnywhere("usage-age")
    }

    func testSettingsShowsTheVersionWithoutABuildNumber() throws {
        launch(mock: true)
        open("Settings")
        needAnywhere("app-version")
        let label = element("app-version").label
        XCTAssertTrue(label.hasPrefix("Version "), "version line reads: \(label)")
        XCTAssertFalse(label.contains("("), "the build number must not show: \(label)")
        XCTAssertNotNil(label.range(of: #"^Version [0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression),
                        "the version line is not a plain marketing version: \(label)")
        // CI passes the version from project.yml, so Settings must show that one.
        if let want = ProcessInfo.processInfo.environment["AGNVIEW_EXPECT_VERSION"], !want.isEmpty {
            XCTAssertEqual(label, "Version " + want, "Settings does not show the project version")
        }
        // The build number is its own row and never part of the version line.
        needAnywhere("app-build")
        XCTAssertNotNil(element("app-build").label.range(of: #"^Build [0-9]+$"#, options: .regularExpression),
                        "build row reads: \(element("app-build").label)")
    }

    /// The agent filter is a menu in the navigation bar and the composer picks
    /// its agent from a menu. Every name shows in full.
    func testConsoleFilterAndAgentMenus() throws {
        launch(mock: true)
        open("Console")
        need("console-filter")
        element("console-filter").tap()
        let option = menuOption("AntiGravity")
        XCTAssertTrue(option.exists, "the filter menu never offered AntiGravity")
        XCTAssertTrue(menuOption("DeepSeek", timeout: 3).exists, "the filter menu has no DeepSeek")
        snap("console-filter-menu")
        option.tap()
        need("filter-summary")
        XCTAssertTrue(element("filter-summary").label.contains("AntiGravity"), "the filter is not shown")
        element("console-filter").tap()
        let all = menuOption("All agents")
        XCTAssertTrue(all.exists, "the filter menu has no All option")
        all.tap()
        XCTAssertFalse(element("filter-summary").exists, "the filter stayed on")

        let prompt = element("composer-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 30))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                object: prompt)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed)
        need("composer-agent")
        element("composer-agent").tap()
        let agent = menuOption("AntiGravity")
        XCTAssertTrue(agent.exists, "the agent menu never offered AntiGravity")
        snap("console-agent-menu")
        agent.tap()
        XCTAssertEqual(element("composer-agent").value as? String, "AntiGravity")
    }

    /// Console and Settings in the dark appearance.
    func testDarkAppearanceConsoleAndSettings() throws {
        launch(mock: true, appearance: "dark")
        open("Console")
        let line = element("status-line")
        need("status-line")
        let healthy = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'healthy'"), object: line)
        XCTAssertEqual(XCTWaiter().wait(for: [healthy], timeout: 20), .completed,
                       "status line never showed the healthy mock hub")
        snap("dark-console")
        open("Settings")
        need("machine-row")
        snap("dark-settings")
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
