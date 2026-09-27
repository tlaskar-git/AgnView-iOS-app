import XCTest

/// Drives a short, scripted walk through the demo app for a marketing screen
/// recording (social media, not App Store submission). This does nothing in
/// an ordinary test run: it runs only when AGNVIEW_MARKETING_VIDEO is 1, which
/// the marketing-video workflow sets while `xcrun simctl io booted
/// recordVideo` is capturing the simulator screen. Every screen shows demo
/// data only, so the recording has nothing that looks like a real machine or
/// account.
final class MarketingVideoTests: DemoUITestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGNVIEW_MARKETING_VIDEO"] == "1",
                          "The marketing video runs only from the marketing-video workflow.")
        try super.setUpWithError()
    }

    /// The pacing sleeps exist only so the recording is watchable: each one
    /// gives a viewer time to read the screen before the next action.
    func testRecording() throws {
        launchUnpaired(appearance: "light")
        need("state-onboarding", timeout: 30)
        Thread.sleep(forTimeInterval: 2)
        need("state-onboarding-demo")
        element("state-onboarding-demo").tap()
        need("demo-banner", timeout: 30)

        // Console: a conversation is already visible from the demo sample data.
        need("console-row", timeout: 30)
        Thread.sleep(forTimeInterval: 2)

        // Send a prompt to the default agent (Claude Code) and show the reply.
        sendPrompt("What should I check before shipping this?")
        closeKeyboard()
        XCTAssertTrue(consoleHas("Demo reply"), "the canned reply never arrived")
        Thread.sleep(forTimeInterval: 2)

        // Switch the agent chip to Codex and show its reply.
        element("composer-agent").tap()
        menuOption("Codex", timeout: 8).tap()
        sendPrompt("Any edge cases in that change?")
        closeKeyboard()
        XCTAssertTrue(consoleHas("Demo reply"), "the Codex canned reply never arrived")
        Thread.sleep(forTimeInterval: 2)

        // Sessions, Pipelines, Usage.
        open("Sessions")
        need("session-row", timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)

        open("Pipelines")
        need("job-row", timeout: 30)
        Thread.sleep(forTimeInterval: 1.5)

        open("Usage")
        needAnywhere("provider-claude", timeout: 40)
        Thread.sleep(forTimeInterval: 1.5)

        // Settings: switch to dark appearance.
        open("Settings")
        need("appearance-picker", timeout: 20)
        Thread.sleep(forTimeInterval: 1)
        let segmented = app.segmentedControls["appearance-picker"].buttons["Dark"]
        if segmented.waitForExistence(timeout: 5) {
            segmented.tap()
        } else {
            app.buttons["Dark"].tap()
        }
        Thread.sleep(forTimeInterval: 1)

        // Back to Console, now in dark mode.
        open("Console")
        need("console-row", timeout: 30)
        Thread.sleep(forTimeInterval: 3)
    }
}
