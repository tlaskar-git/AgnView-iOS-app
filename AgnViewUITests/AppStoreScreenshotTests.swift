import XCTest

/// Captures the App Store screenshots in demo mode. The class does nothing in
/// the ordinary test run: it runs only when AGNVIEW_APPSTORE_SHOTS is 1, which
/// the appstore-screenshots workflow sets. Every screenshot holds demo data
/// only, and every file name starts with AGNVIEW_SHOT_PREFIX or, when that is
/// not set, with iphone-6.9 or ipad-13.
final class AppStoreScreenshotTests: DemoUITestCase {
    private var prefix: String {
        let set = ProcessInfo.processInfo.environment["AGNVIEW_SHOT_PREFIX"] ?? ""
        if !set.isEmpty { return set }
        return isPad ? "ipad-13" : "iphone-6.9"
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGNVIEW_APPSTORE_SHOTS"] == "1",
                          "App Store screenshots run only from the appstore-screenshots workflow.")
        try super.setUpWithError()
    }

    private func snap(_ name: String) {
        Thread.sleep(forTimeInterval: 1.0)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(prefix)-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Six screens in the light appearance.
    func testLightScreens() throws {
        startDemoFromOnboarding(appearance: "light")

        // 01: the console with a running conversation.
        open("Console")
        need("console-row", timeout: 30)
        XCTAssertTrue(consoleHas("Add input validation"))
        sendPrompt("Add a short section about the demo project to the readme.")
        closeKeyboard()
        XCTAssertTrue(consoleHas("Demo reply"), "the canned reply never arrived")
        // Let a few live lines arrive so the log looks busy.
        Thread.sleep(forTimeInterval: 9)
        snap("01-console")

        // 02: the keyboard with the composer menus.
        let prompt = element("composer-prompt")
        prompt.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "the keyboard never appeared")
        let chip = element("toolbar-model").waitForExistence(timeout: 5) ? element("toolbar-model")
                                                                          : element("composer-model")
        chip.tap()
        let option = menuOption("Medium", timeout: 8)
        XCTAssertTrue(option.exists, "the model menu never opened")
        snap("02-console-keyboard-menu")
        option.tap()
        closeKeyboard()

        // 03 and 04: Sessions and Pipelines.
        open("Sessions")
        need("session-row", timeout: 30)
        snap("03-sessions")
        open("Pipelines")
        need("job-row", timeout: 30)
        snap("04-pipelines")

        // 05: the New pipeline form, filled in.
        need("pipelines-new")
        element("pipelines-new").tap()
        need("new-pipeline")
        let title = element("np-title")
        title.tap()
        title.typeText("Release checklist")
        let taskTitle = element("np-task-title")
        taskTitle.tap()
        taskTitle.typeText("Write the release notes")
        let done = element("np-keyboard-done")
        if done.waitForExistence(timeout: 3) { done.tap() }
        snap("05-new-pipeline")
        element("np-create").tap()
        need("job-detail", timeout: 30)

        // 06: Usage.
        open("Usage")
        needAnywhere("provider-claude", timeout: 40)
        needAnywhere("usage-window")
        for _ in 0..<4 where element("provider-claude").exists && !element("provider-claude").isHittable {
            app.swipeDown()
        }
        snap("06-usage")
    }

    /// Two extra screens in the dark appearance.
    func testDarkScreens() throws {
        startDemoFromOnboarding(appearance: "dark")
        open("Console")
        need("console-row", timeout: 30)
        XCTAssertTrue(consoleHas("Add input validation"))
        Thread.sleep(forTimeInterval: 9)
        snap("07-console-dark")
        open("Usage")
        needAnywhere("provider-claude", timeout: 40)
        needAnywhere("usage-window")
        snap("08-usage-dark")
    }
}
