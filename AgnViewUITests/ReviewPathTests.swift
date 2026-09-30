import XCTest

/// The path an App Review reviewer takes on a new install: launch with no
/// launch arguments, tap Try the demo, then use every screen and send a
/// prompt. At every step it looks for anything a reviewer would read as an
/// error. The class does nothing in the ordinary test run: it runs only when
/// AGNVIEW_REVIEW_PATH is 1, which the review-path workflow sets. That
/// workflow installs the app on a new simulator for every run.
///
/// AGNVIEW_REVIEW_DELAY is the number of seconds to wait on the onboarding
/// screen before the tap (0 taps as soon as the button exists).
/// AGNVIEW_REVIEW_LANDSCAPE set to 1 turns the device to landscape first.
final class ReviewPathTests: DemoUITestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["AGNVIEW_REVIEW_PATH"] == "1",
                          "The review path runs only from the review-path workflow.")
        try super.setUpWithError()
        // Collect every problem of the run, not only the first.
        continueAfterFailure = true
    }

    /// Prints one line the workflow collects into its summary.
    private func report(_ text: String) {
        print("REVIEW-PATH: " + text)
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "review-" + name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func keepTree(_ name: String) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "review-tree-" + name
        tree.lifetime = .keepAlways
        add(tree)
    }

    /// Everything on screen a reviewer would read as an error.
    private func problems() -> [String] {
        var found: [String] = []
        let identifiers = ["composer-error", "composer-notice", "banner-notice", "banner-relay-only",
                           "banner-not-on-network", "pairing-failure", "task-action-error",
                           "usage-account-error", "state-offline", "state-authFailed", "state-keyRevoked"]
        for id in identifiers where element(id).exists {
            let label = element(id).label
            found.append(id + (label.isEmpty ? "" : ": " + label))
        }
        let words = NSPredicate(format: """
            (label CONTAINS[c] 'error' OR label CONTAINS[c] 'could not' OR label CONTAINS[c] 'failed' \
            OR label CONTAINS[c] 'can\\'t' OR label CONTAINS[c] 'not found' OR label CONTAINS[c] 'rejected' \
            OR label CONTAINS[c] 'not supported' OR label CONTAINS[c] 'try again') \
            AND NOT (label CONTAINS[c] '0 failed')
            """)
        for text in app.staticTexts.matching(words).allElementsBoundByIndex.prefix(5) {
            found.append("text: " + text.label)
        }
        if app.alerts.count > 0 {
            found.append("alert: " + app.alerts.firstMatch.label)
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.count > 0 {
            found.append("system alert: " + springboard.alerts.firstMatch.label)
        }
        if app.state != .runningForeground {
            found.append("app state: \(app.state.rawValue)")
        }
        return found
    }

    private func check(_ step: String) {
        let found = problems()
        if found.isEmpty {
            report("step \(step): clean")
            return
        }
        report("step \(step): PROBLEM " + found.joined(separator: " | "))
        snap("problem-" + step)
        keepTree(step)
        XCTFail("\(step): " + found.joined(separator: " | "))
    }

    func testReviewerPath() throws {
        let delay = Double(environment["AGNVIEW_REVIEW_DELAY"] ?? "") ?? 0
        if environment["AGNVIEW_REVIEW_LANDSCAPE"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
        } else {
            XCUIDevice.shared.orientation = .portrait
        }
        report("device \(isPad ? "ipad" : "iphone"), delay \(delay), landscape \(environment["AGNVIEW_REVIEW_LANDSCAPE"] ?? "0")")

        // No launch arguments and no environment: the app as a reviewer gets it.
        // The one exception: the Thread Sanitizer run writes its report to a file.
        app = XCUIApplication()
        if let tsan = environment["AGNVIEW_REVIEW_TSAN_LOG"], !tsan.isEmpty {
            app.launchEnvironment["TSAN_OPTIONS"] = "log_path=\(tsan):halt_on_error=0"
        }
        let launched = Date()
        app.launch()
        let demoButton = element("state-onboarding-demo")
        XCTAssertTrue(demoButton.waitForExistence(timeout: 60), "Try the demo never appeared")
        report(String(format: "onboarding after %.2fs", Date().timeIntervalSince(launched)))
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        snap("01-onboarding")
        check("onboarding")

        demoButton.tap()
        let tapped = Date()
        let banner = element("demo-banner").waitForExistence(timeout: 30)
        report(String(format: "demo banner %@ after %.2fs", banner ? "shown" : "MISSING", Date().timeIntervalSince(tapped)))
        XCTAssertTrue(banner, "the demo banner never appeared")
        snap("02-demo-started")
        check("demo-started")

        // Console first: the screen the reviewer lands on.
        let firstRow = element("console-row").waitForExistence(timeout: 30)
        report(String(format: "first console row %@ after %.2fs", firstRow ? "shown" : "MISSING", Date().timeIntervalSince(tapped)))
        XCTAssertTrue(firstRow, "the sample conversation never appeared")
        XCTAssertEqual(element("route-pill").label, "Connection: Demo")
        waitForComposer()
        let prompt = element("composer-prompt")
        prompt.tap()
        prompt.typeText("Hello from the review path")
        let sent = Date()
        element("composer-send").tap()
        let confirmed = element("composer-result").waitForExistence(timeout: 30)
        report(String(format: "confirmation %@ after %.2fs", confirmed ? "shown" : "MISSING", Date().timeIntervalSince(sent)))
        XCTAssertTrue(confirmed, "no confirmation after Send")
        if confirmed {
            XCTAssertEqual(element("composer-result").label, "Demo mode. Sent to the sample console only.")
        }
        check("console-sent")
        closeKeyboard()
        let replied = consoleHas("Your prompt was: Hello from the review path", timeout: 30)
        report(String(format: "canned reply %@ after %.2fs", replied ? "shown" : "MISSING", Date().timeIntervalSince(sent)))
        XCTAssertTrue(replied, "the canned reply never reached the console")
        snap("03-console-reply")
        if !replied { keepTree("console-no-reply") }
        check("console-reply")

        for (name, root) in [("Sessions", "session-row"), ("Pipelines", "job-row"), ("Usage", "provider-claude"),
                             ("Settings", "exit-demo")] {
            open(name)
            let shown = name == "Usage" ? findAnywhere(root, timeout: 30) : element(root).waitForExistence(timeout: 30)
            report("\(name): \(root) \(shown ? "shown" : "MISSING")")
            XCTAssertTrue(shown, "\(name) never showed \(root)")
            XCTAssertTrue(element("demo-banner").exists, "\(name) lost the demo banner")
            snap("04-" + name.lowercased())
            check(name.lowercased())
        }

        // Open a pipeline, as a reviewer would.
        open("Pipelines")
        if element("job-row").waitForExistence(timeout: 20) {
            element("job-row").tap()
            let detail = element("job-detail").waitForExistence(timeout: 20)
            report("pipeline detail \(detail ? "shown" : "MISSING")")
            XCTAssertTrue(detail, "the pipeline detail never opened")
            snap("05-pipeline-detail")
            check("pipeline-detail")
        }

        // Back to the console: the demo must still answer.
        open("Console")
        waitForComposer()
        prompt.tap()
        prompt.typeText("Second prompt")
        let second = Date()
        element("composer-send").tap()
        _ = element("composer-result").waitForExistence(timeout: 30)
        closeKeyboard()
        let secondReply = consoleHas("Your prompt was: Second prompt", timeout: 30)
        report(String(format: "second reply %@ after %.2fs", secondReply ? "shown" : "MISSING", Date().timeIntervalSince(second)))
        XCTAssertTrue(secondReply, "the second reply never reached the console")
        snap("06-console-second")
        check("console-second")
        report("done")
    }
}
