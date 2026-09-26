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

    /// The route pill sits on the right of the header, fully on screen, at the
    /// approved inset from the edge and at the approved size.
    private func assertPillVisible(file: StaticString = #filePath, line: UInt = #line) {
        let pill = element("route-pill")
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "route-pill missing", file: file, line: line)
        let window = app.windows.firstMatch.frame
        let frame = pill.frame
        XCTAssertTrue(window.contains(frame), "the pill is cut off: \(frame) in \(window)", file: file, line: line)
        let inset: CGFloat = isPad ? 24 : 16
        XCTAssertEqual(window.maxX - frame.maxX, inset, accuracy: 3,
                       "the pill is not at the right inset: \(frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 36, "the pill is too short: \(frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.width, 76, "the pill is too narrow: \(frame)", file: file, line: line)
    }

    /// Taps the chat area near the top, away from the composer.
    private func tapChat() {
        element("console-log").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
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
            // The floating tab bar draws its own buttons: tab-sessions, tab-console and so on.
            let tab = app.buttons["tab-" + name.lowercased()]
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
            assertPillVisible()
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

    /// Two machines: the active one says Active, the other has a Switch button
    /// with a 44 pt target. Tapping the row opens its details. Tapping Switch
    /// switches at once and confirms with a toast.
    func testSettingsSwitchButton() throws {
        launch(state: "machines")
        open("Settings")
        need("machine-row")
        need("machine-active")
        need("machine-switch-button")
        let button = element("machine-switch-button")
        XCTAssertGreaterThanOrEqual(button.frame.height, 44, "the Switch target is under 44 pt")
        XCTAssertGreaterThanOrEqual(button.frame.width, 72, "the Switch button is narrower than 72 pt")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Switch opens a menu or dialog instead of switching")
        snap("settings-switch")

        // The row opens the details, with the name field and Remove.
        element("machine-open").tap()
        need("machine-detail")
        need("machine-name")
        need("machine-remove")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        need("machine-switch-button")

        element("machine-switch-button").tap()
        need("toast")
        XCTAssertTrue(element("toast").label.hasPrefix("Switched to"), "no confirmation: \(element("toast").label)")
        need("machine-active")
        need("machine-switch-button")
        assertPillVisible()
    }

    /// The Console shows a conversation: bubbles, plain agent replies, a code
    /// block with Copy, the composer chips and no filter menu or Done button.
    func testConsoleConversation() throws {
        launch(state: "machines")
        open("Console")
        need("console-log")
        need("console-row", timeout: 30)
        need("code-block")
        need("code-copy")
        need("composer-agent")
        need("composer-model")
        need("composer-effort")
        need("composer-attach")
        need("composer-send")
        need("tab-console")
        XCTAssertFalse(element("console-filter").exists, "the filter menu is gone from the Console")
        XCTAssertFalse(element("keyboard-done").exists)
        assertPillVisible()
        snap("console-chat")

        let prompt = element("composer-prompt")
        prompt.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard never appeared")
        XCTAssertFalse(element("keyboard-done").exists, "there is a Done button")
        need("composer-send")
        XCTAssertTrue(element("composer-send").isHittable, "Send is covered")
        if !isPad {
            let tab = element("tab-sessions")
            XCTAssertFalse(tab.exists && tab.isHittable, "the tab bar stays over the keyboard")
        }
        snap("console-chat-keyboard")
        tapChat()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 10), .completed,
                       "tapping the chat did not close the keyboard")
    }

    /// The floating tab bar on iPhone: Sessions, Pipelines, Console, Usage,
    /// Settings from left to right. The app opens on Console. A tap changes
    /// the screen and a second tap stays on it.
    func testTabBarOrderAndSelection() throws {
        try XCTSkipIf(isPad, "iPad uses the sidebar")
        launch(mock: true)
        let ids = ["tab-sessions", "tab-pipelines", "tab-console", "tab-usage", "tab-settings"]
        for id in ids { need(id) }
        let xs = ids.map { element($0).frame.midX }
        XCTAssertEqual(xs, xs.sorted(), "the tabs are not in order from left to right: \(xs)")
        XCTAssertTrue(element("tab-console").isSelected, "the app must open on Console")
        need("screen-console")
        element("tab-usage").tap()
        need("screen-usage")
        XCTAssertTrue(element("tab-usage").isSelected)
        XCTAssertFalse(element("tab-console").isSelected)
        element("tab-usage").tap()
        need("screen-usage")
        element("tab-console").tap()
        need("screen-console")
        XCTAssertTrue(element("tab-console").isSelected)
        XCTAssertEqual(element("tab-settings").label, "Settings")
        XCTAssertEqual(element("tab-console").value as? String, "tab 3 of 5")
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
        // There is no Done button. Tapping the chat closes the keyboard.
        XCTAssertFalse(element("keyboard-done").exists, "there is a Done button")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard should stay after Send")
        tapChat()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                               object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 10), .completed,
                       "tapping the chat did not close the keyboard")
    }

    /// The keyboard has no toolbar. Agent, Model and Effort stay in the
    /// composer chips above it and nothing sits over Send.
    func testKeyboardHasNoToolbarAndSendStaysReachable() throws {
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
        XCTAssertFalse(element("keyboard-done").exists, "there is a Done button")
        XCTAssertFalse(element("toolbar-model").exists, "there is a keyboard toolbar")
        need("composer-send")
        XCTAssertTrue(element("composer-send").isHittable, "Send is covered")
        XCTAssertTrue(element("composer-agent").isHittable, "the agent chip is covered")
        snap("console-keyboard")
        tapChat()
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

    /// The Console has no filter menu. The composer picks its agent from a menu
    /// that always lists Claude Code, Codex, AntiGravity, DeepSeek in that
    /// order, whichever agent is chosen. Every name shows in full.
    func testConsoleAgentMenuKeepsAFixedOrder() throws {
        launch(mock: true)
        open("Console")
        XCTAssertFalse(element("console-filter").exists, "the filter menu is still there")
        XCTAssertFalse(element("filter-summary").exists)

        let prompt = element("composer-prompt")
        XCTAssertTrue(prompt.waitForExistence(timeout: 30))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"),
                                                object: prompt)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 30), .completed)
        need("composer-agent")

        // Choose a different agent first, so a menu that sorts by selection would show it.
        chooseAgent("codex", name: "Codex")
        XCTAssertEqual(element("composer-agent").value as? String, "Codex")

        element("composer-agent").tap()
        let names = ["Claude Code", "Codex", "AntiGravity", "DeepSeek"]
        var tops: [CGFloat] = []
        for name in names {
            let item = menuOption(name)
            XCTAssertTrue(item.exists, "the agent menu never offered \(name)")
            tops.append(item.frame.minY)
        }
        XCTAssertEqual(tops, tops.sorted(), "the agent menu is not in the fixed order: \(tops)")
        XCTAssertEqual(Set(tops).count, names.count, "two agents share a row: \(tops)")
        snap("console-agent-menu")
        menuOption("AntiGravity").tap()
        XCTAssertEqual(element("composer-agent").value as? String, "AntiGravity")

        // The order does not move when another agent is chosen.
        element("composer-agent").tap()
        var again: [CGFloat] = []
        for name in names { again.append(menuOption(name).frame.minY) }
        XCTAssertEqual(again, again.sorted(), "the order changed with the selection: \(again)")
        menuOption("Claude Code").tap()
        XCTAssertEqual(element("composer-agent").value as? String, "Claude Code")
    }

    /// Console and Settings in the dark appearance, with a conversation and
    /// two machines.
    func testDarkAppearanceConsoleAndSettings() throws {
        launch(state: "machines", appearance: "dark")
        open("Console")
        need("console-row", timeout: 30)
        need("code-block")
        snap("dark-console")
        open("Settings")
        need("machine-row")
        need("machine-switch-button")
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
