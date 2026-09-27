import XCTest

/// Demo mode as an App Review reviewer meets it: no machine, no network, one tap.
final class DemoModeUITests: DemoUITestCase {
    func testOnboardingOffersTheDemoAndTheDesktopLink() throws {
        launchUnpaired()
        need("state-onboarding", timeout: 30)
        need("state-onboarding-primary")
        need("state-onboarding-demo")
        need("state-onboarding-get-desktop")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'companion'")).firstMatch.waitForExistence(timeout: 5),
                      "the onboarding text does not say that the app is a companion")
    }

    func testDemoReachesEveryScreen() throws {
        startDemoFromOnboarding()
        for name in ["Console", "Sessions", "Pipelines", "Usage", "Settings"] {
            open(name)
            need("demo-banner")
            need("route-pill")
            XCTAssertEqual(element("route-pill").label, "Connection: Demo")
            switch name {
            case "Console":
                need("console-row", timeout: 30)
                XCTAssertTrue(consoleHas("Add input validation"), "the sample conversation is missing")
            case "Sessions":
                need("session-row", timeout: 30)
            case "Pipelines":
                need("job-row", timeout: 30)
            case "Usage":
                needAnywhere("provider-claude", timeout: 40)
                needAnywhere("usage-window")
                needAnywhere("usage-breakdown")
                needAnywhere("usage-age", timeout: 5)
            default:
                need("exit-demo")
                needAnywhere("about-privacy")
                needAnywhere("app-version")
            }
        }
    }

    func testDemoPromptGetsACannedReplyAndMenusWork() throws {
        startDemoFromOnboarding()
        open("Console")
        waitForComposer()
        var picked = false
        for _ in 0..<6 where !picked {
            element("composer-model").tap()
            let option = menuOption("Large", timeout: 5)
            if option.exists {
                option.tap()
                picked = true
            } else {
                element("console-log").tap()
                Thread.sleep(forTimeInterval: 2)
            }
        }
        XCTAssertTrue(picked, "the demo model list never reached the menu")
        element("composer-effort").tap()
        let low = menuOption("Low Effort")
        XCTAssertTrue(low.exists, "the demo effort list never reached the menu")
        low.tap()
        sendPrompt("Hello from the demo")
        // The keyboard hides most of the log on a phone. Close it so the new rows are on screen.
        closeKeyboard()
        XCTAssertTrue(consoleHas("Demo reply"), "the canned reply never reached the console")
        XCTAssertTrue(element("composer-result").label.contains("Demo mode"))
    }

    func testDemoCreatesAPipelineAndRefreshWorks() throws {
        startDemoFromOnboarding()
        open("Pipelines")
        need("job-row", timeout: 30)
        let plus = element("pipelines-new")
        need("pipelines-new")
        XCTAssertTrue(plus.isEnabled, "New pipeline is disabled in the demo")
        plus.tap()
        need("new-pipeline")
        let title = element("np-title")
        title.tap()
        title.typeText("Demo checklist")
        let taskTitle = element("np-task-title")
        taskTitle.tap()
        taskTitle.typeText("Read the notes")
        let done = element("np-keyboard-done")
        if done.waitForExistence(timeout: 3) { done.tap() }
        element("np-create").tap()
        need("job-detail", timeout: 30)
        XCTAssertEqual(element("job-detail-title").label, "Demo checklist")

        open("Usage")
        need("usage-refresh")
        element("usage-refresh").tap()
        needAnywhere("usage-age")

        open("Sessions")
        need("sessions-refresh")
        element("sessions-refresh").tap()
        need("sessions-updated")
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH 'Updated'"),
                                                object: element("sessions-updated"))
        XCTAssertEqual(XCTWaiter().wait(for: [updated], timeout: 20), .completed)
    }

    func testDemoStartsFromSettingsAndExits() throws {
        launchUnpaired()
        need("state-onboarding", timeout: 30)
        open("Settings")
        needAnywhere("settings-try-demo")
        element("settings-try-demo").tap()
        need("demo-banner", timeout: 30)
        needAnywhere("exit-demo")
        element("exit-demo").tap()
        needAnywhere("settings-try-demo")
        XCTAssertFalse(element("demo-banner").exists, "the demo banner stayed after Exit demo")
        open("Console")
        need("state-onboarding")
    }

    func testAboutLinksAndAcknowledgements() throws {
        launchUnpaired()
        need("state-onboarding", timeout: 30)
        open("Settings")
        needAnywhere("app-version")
        needAnywhere("app-build")
        needAnywhere("about-privacy")
        needAnywhere("about-support")
        needAnywhere("about-get-desktop")
        needAnywhere("about-acknowledgements")
        let row = hittable("about-acknowledgements", timeout: 10) ?? element("about-acknowledgements")
        row.tap()
        let opened = app.navigationBars["Acknowledgements"].waitForExistence(timeout: 10)
            || element("acknowledgements").waitForExistence(timeout: 5)
        XCTAssertTrue(opened, "the Acknowledgements screen never opened")
        let names = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'iroh-ffi'"))
        XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 5), "iroh-ffi is not listed")
    }
}
