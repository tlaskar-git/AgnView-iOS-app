import XCTest
@testable import AgnView

final class AgnViewTests: XCTestCase {
    func testRouteLabels() {
        XCTAssertEqual(Route.lan.label, "LAN")
        XCTAssertEqual(Route.direct.label, "Direct")
        XCTAssertEqual(Route.relay.label, "Relay")
        XCTAssertEqual(Route.offline.label, "Offline")
        XCTAssertEqual(Route.allCases.count, 4)
    }

    func testScreenOrder() {
        XCTAssertEqual(Screen.allCases.map(\.title),
                       ["Console", "Sessions", "Pipelines", "Usage", "Settings"])
        XCTAssertEqual(Screen.console.identifier, "screen-console")
    }

    func testDecodeUsageSample() throws {
        let json = """
        [{"id":"acc-1","name":"Example account","provider":"claude","plan_name":"Example plan",
          "tokens_used":1200,"tokens_limit":10000,"cost_used":1.5,"cost_limit":null,
          "requests_count":7,"last_probed":null,"is_active":true}]
        """
        let accounts = try UsageAccount.decodeList(from: Data(json.utf8))
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts[0].provider, "claude")
        XCTAssertEqual(accounts[0].tokensLimit, 10000)
        XCTAssertNil(accounts[0].costLimit)
        XCTAssertTrue(accounts[0].isActive)
    }
}
