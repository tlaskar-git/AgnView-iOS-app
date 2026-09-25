import XCTest
@testable import AgnView

/// The Keychain round trip needs an ad-hoc signed simulator build. Unsigned
/// builds return errSecMissingEntitlement (-34018) for every Keychain call.
final class KeychainStoreTests: XCTestCase {
    func testKeychainRoundTrip() throws {
        let store = KeychainStore(service: "com.example.agnview.tests.\(UUID().uuidString)")
        let account = "test-account"
        defer { try? store.delete(account: account) }
        XCTAssertNil(try store.get(account: account))
        try store.set(Data([1, 2, 3]), account: account)
        XCTAssertEqual(try store.get(account: account), Data([1, 2, 3]))
        try store.set(Data([4]), account: account)
        XCTAssertEqual(try store.get(account: account), Data([4]))
        try store.delete(account: account)
        XCTAssertNil(try store.get(account: account))
    }

    func testInMemoryStore() throws {
        let store = InMemorySecretStore()
        XCTAssertNil(try store.get(account: "a"))
        try store.set(Data([1, 2, 3]), account: "a")
        XCTAssertEqual(try store.get(account: "a"), Data([1, 2, 3]))
        try store.set(Data([4]), account: "a")
        XCTAssertEqual(try store.get(account: "a"), Data([4]))
        try store.delete(account: "a")
        XCTAssertNil(try store.get(account: "a"))
    }
}
