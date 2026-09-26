import Foundation
import Combine

/// Non-secret hub metadata. The pairing key lives in the SecretStore, never here.
struct HubRecord: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var lanHost: String
    var lanPort: Int
    var fingerprint: String
    var irohTicket: String?
    var order: Int
    var everConnected: Bool
}

final class HubStore: ObservableObject {
    private struct Snapshot: Codable {
        var hubs: [HubRecord]
        var activeHubId: String?
    }

    @Published private(set) var hubs: [HubRecord] = []
    @Published private(set) var activeHubId: String?

    private let secrets: SecretStore
    private let fileURL: URL

    init(secrets: SecretStore, directory: URL) {
        self.secrets = secrets
        self.fileURL = directory.appendingPathComponent("hubs.json")
        if let data = try? Data(contentsOf: fileURL),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            let sorted = snap.hubs.sorted { $0.order < $1.order }
            hubs = sorted
            if let id = snap.activeHubId, sorted.contains(where: { $0.id == id }) {
                activeHubId = id
            } else {
                activeHubId = sorted.first?.id
            }
        }
    }

    /// Stores the key, then the record. Replaces a record with the same id.
    @discardableResult
    func add(payload: PairingPayload) throws -> HubRecord {
        let id = payload.hubIdString
        try secrets.set(payload.key, account: id)
        var next = hubs
        let order: Int
        if let index = next.firstIndex(where: { $0.id == id }) {
            order = next[index].order
        } else {
            order = (next.map(\.order).max() ?? -1) + 1
        }
        let record = HubRecord(id: id, name: payload.name, lanHost: payload.lanHost,
                               lanPort: payload.lanPort, fingerprint: payload.fingerprint,
                               irohTicket: payload.irohTicket, order: order, everConnected: false)
        if let index = next.firstIndex(where: { $0.id == id }) {
            next[index] = record
        } else {
            next.append(record)
        }
        let active = activeHubId ?? id
        try persist(hubs: next, active: active)
        hubs = next
        activeHubId = active
        return record
    }

    func setActive(_ id: String) {
        guard hubs.contains(where: { $0.id == id }) else { return }
        try? persist(hubs: hubs, active: id)
        activeHubId = id
    }

    /// Changes the name shown on this phone. The key and the hub stay the same.
    /// An empty name is ignored. Returns true when the name changed.
    @discardableResult
    func rename(id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = hubs.firstIndex(where: { $0.id == id }),
              hubs[index].name != trimmed else { return false }
        var next = hubs
        next[index].name = trimmed
        guard (try? persist(hubs: next, active: activeHubId)) != nil else { return false }
        hubs = next
        return true
    }

    /// Deletes the key and the record. Promotes the next hub when the active one goes.
    func remove(id: String) throws {
        try secrets.delete(account: id)
        let next = hubs.filter { $0.id != id }
        var active = activeHubId
        if active == id { active = next.first?.id }
        try persist(hubs: next, active: active)
        hubs = next
        activeHubId = active
    }

    func key(for id: String) throws -> Data? {
        try secrets.get(account: id)
    }

    func markConnected(id: String) {
        guard let index = hubs.firstIndex(where: { $0.id == id }), !hubs[index].everConnected else { return }
        var next = hubs
        next[index].everConnected = true
        try? persist(hubs: next, active: activeHubId)
        hubs = next
    }

    private func persist(hubs: [HubRecord], active: String?) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Snapshot(hubs: hubs, activeHubId: active))
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
