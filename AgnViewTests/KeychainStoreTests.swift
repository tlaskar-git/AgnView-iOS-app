import XCTest
@testable import AgnView

/// The KeychainStore round trip is not tested here. Unsigned CI simulator builds
/// return errSecMissingEntitlement (-34018) for every Keychain call.
final class KeychainStoreTests: XCTestCase {
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
