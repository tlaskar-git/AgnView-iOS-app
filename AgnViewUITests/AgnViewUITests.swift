import XCTest

final class AgnViewUITests: XCTestCase {
    private var app: XCUIApplication!
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        let hub = ProcessInfo.processInfo.environment["AGNVIEW_MOCK_HUB_URL"] ?? "http://127.0.0.1:18081"
        app.launchEnvironment["AGNVIEW_MOCK_HUB_URL"] = hub
        app.launch()
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

    private func open(_ name: String) {
        if isPad {
            // The identifier is shared by the cell and its children, so pick a hittable match.
            let id = "nav-" + name.lowercased()
            var row = hittable(id, timeout: 3)
            if row == nil {
                // Sidebar hidden in this orientation: reveal it.
                let toggle = app.navigationBars.buttons.firstMatch
                if toggle.exists { toggle.tap() }
                row = hittable(id, timeout: 10)
            }
            XCTAssertNotNil(row, "sidebar item \(name) missing")
            row?.tap()
        } else {
            let tab = app.tabBars.buttons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 10), "tab \(name) missing")
            tab.tap()
        }
    }

    func testVisitAllScreens() throws {
        let device = isPad ? "ipad" : "iphone"
        for name in ["Console", "Sessions", "Pipelines", "Usage", "Settings"] {
            let key = name.lowercased()
            open(name)
            let screen = app.descendants(matching: .any)["screen-" + key].firstMatch
            XCTAssertTrue(screen.waitForExistence(timeout: 10), "screen-\(key) missing")
            XCTAssertTrue(app.descendants(matching: .any)["route-pill"].firstMatch.exists)
            if key == "console" {
                let line = app.descendants(matching: .any)["status-line"].firstMatch
                XCTAssertTrue(line.waitForExistence(timeout: 10))
                let healthy = NSPredicate(format: "label CONTAINS 'healthy'")
                expectation(for: healthy, evaluatedWith: line)
                waitForExpectations(timeout: 15)
            }
            if key == "usage" {
                let provider = app.descendants(matching: .any)["provider-claude"].firstMatch
                XCTAssertTrue(provider.waitForExistence(timeout: 15), "mock hub data missing")
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(device)-\(key)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }
}
