import XCTest
@testable import AgnView

final class KeychainStoreTests: XCTestCase {
    private let service = "com.example.agnview.tests.\(UUID().uuidString)"
    private let account = "test-account"

    override func tearDown() {
        try? KeychainStore(service: service).delete(account: account)
        super.tearDown()
    }

    func testRoundTrip() throws {
        let store = KeychainStore(service: service)
        XCTAssertNil(try store.get(account: account))
        let first = Data(repeating: 0x41, count: 32)
        try store.set(first, account: account)
        XCTAssertEqual(try store.get(account: account), first)
        let second = Data(repeating: 0x43, count: 32)
        try store.set(second, account: account)
        XCTAssertEqual(try store.get(account: account), second)
        try store.delete(account: account)
        XCTAssertNil(try store.get(account: account))
        try store.delete(account: account)
    }

    func testInMemoryStore() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.get(account: "a"))
        try store.set(Data([1, 2, 3]), account: "a")
        XCTAssertEqual(try store.get(account: "a"), Data([1, 2, 3]))
        try store.delete(account: "a")
        XCTAssertNil(try store.get(account: "a"))
    }
}
