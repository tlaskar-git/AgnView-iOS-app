import XCTest
@testable import AgnView

final class HubStoreTests: XCTestCase {
    private var dir: URL!
    private var secrets: InMemorySecretStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hubstore-\(UUID().uuidString)", isDirectory: true)
        secrets = InMemorySecretStore()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func payload(idByte: UInt8 = 0x42, keyByte: UInt8 = 0x41, name: String = "Test Hub") -> PairingPayload {
        PairingPayload(version: 1, name: name, lanHost: "192.0.2.10", lanPort: 18845,
                       fingerprint: String(repeating: "a", count: 64),
                       hubId: Data(repeating: idByte, count: 16),
                       key: Data(repeating: keyByte, count: 32), irohTicket: nil)
    }

    private func makeStore() -> HubStore { HubStore(secrets: secrets, directory: dir) }

    func testAddStoresRecordAndKey() throws {
        let store = makeStore()
        let p = payload()
        let record = try store.add(payload: p)
        XCTAssertEqual(record.id, p.hubIdString)
        XCTAssertEqual(record.name, "Test Hub")
        XCTAssertFalse(record.everConnected)
        XCTAssertEqual(store.hubs, [record])
        XCTAssertEqual(store.activeHubId, record.id)
        XCTAssertEqual(try store.key(for: record.id), p.key)
    }

    func testReplaceSameId() throws {
        let store = makeStore()
        _ = try store.add(payload: payload(name: "Old"))
        let updated = try store.add(payload: payload(keyByte: 0x43, name: "New"))
        XCTAssertEqual(store.hubs.count, 1)
        XCTAssertEqual(store.hubs[0].name, "New")
        XCTAssertEqual(try store.key(for: updated.id), Data(repeating: 0x43, count: 32))
    }

    func testActiveSwitching() throws {
        let store = makeStore()
        let a = try store.add(payload: payload(idByte: 0x01))
        let b = try store.add(payload: payload(idByte: 0x02))
        XCTAssertEqual(store.activeHubId, a.id)
        XCTAssertLessThan(a.order, b.order)
        store.setActive(b.id)
        XCTAssertEqual(store.activeHubId, b.id)
        store.setActive("unknown")
        XCTAssertEqual(store.activeHubId, b.id)
    }

    func testRemoveDeletesKeyAndRecord() throws {
        let store = makeStore()
        let a = try store.add(payload: payload(idByte: 0x01))
        try store.remove(id: a.id)
        XCTAssertTrue(store.hubs.isEmpty)
        XCTAssertNil(store.activeHubId)
        XCTAssertNil(try store.key(for: a.id))
    }

    func testRemoveActivePromotesNext() throws {
        let store = makeStore()
        let a = try store.add(payload: payload(idByte: 0x01))
        let b = try store.add(payload: payload(idByte: 0x02))
        try store.remove(id: a.id)
        XCTAssertEqual(store.activeHubId, b.id)
        XCTAssertEqual(store.hubs.map(\.id), [b.id])
    }

    func testRemoveInactiveKeepsActive() throws {
        let store = makeStore()
        let a = try store.add(payload: payload(idByte: 0x01))
        let b = try store.add(payload: payload(idByte: 0x02))
        try store.remove(id: b.id)
        XCTAssertEqual(store.activeHubId, a.id)
    }

    func testEverConnectedPersistsAcrossReload() throws {
        let store = makeStore()
        let a = try store.add(payload: payload(idByte: 0x01))
        let b = try store.add(payload: payload(idByte: 0x02))
        store.markConnected(id: a.id)
        store.setActive(b.id)
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.hubs.count, 2)
        XCTAssertTrue(reloaded.hubs.first { $0.id == a.id }!.everConnected)
        XCTAssertFalse(reloaded.hubs.first { $0.id == b.id }!.everConnected)
        XCTAssertEqual(reloaded.activeHubId, b.id)
        XCTAssertEqual(try reloaded.key(for: a.id), Data(repeating: 0x41, count: 32))
    }

    func testJSONFileContainsNoKeyMaterial() throws {
        let store = makeStore()
        let p = payload()
        _ = try store.add(payload: p)
        let data = try Data(contentsOf: dir.appendingPathComponent("hubs.json"))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains(p.key.base64EncodedString()))
        XCTAssertFalse(text.contains(Base64URL.encode(p.key)))
        XCTAssertTrue(text.contains("Test Hub"))
    }
}
