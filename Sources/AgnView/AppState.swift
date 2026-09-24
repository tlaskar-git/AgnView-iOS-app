import Foundation

#if DEBUG
/// Debug-only test hub support. Release builds never read the variable.
enum MockHub {
    static let pairingKey = "test-key-not-real"

    static var baseURL: URL? {
        guard let value = ProcessInfo.processInfo.environment["AGNVIEW_MOCK_HUB_URL"],
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    static func get(_ path: String, base: URL) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue(pairingKey, forHTTPHeaderField: "X-Pairing-Key")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
#endif

@MainActor
final class AppState: ObservableObject {
    @Published var route: Route = .offline
    @Published var usage: [UsageAccount] = []
    @Published var statusLine: String = "No hub connected"

    func refresh() async {
        #if DEBUG
        guard let base = MockHub.baseURL else { return }
        do {
            let statusData = try await MockHub.get("api/mobile/status", base: base)
            let usageData = try await MockHub.get("api/usage/accounts", base: base)
            let status = try MobileStatus.decode(from: statusData)
            usage = try UsageAccount.decodeList(from: usageData)
            statusLine = "\(status.service) \(status.version): \(status.status)"
            route = .lan
        } catch {
            statusLine = "Mock hub unreachable"
            route = .offline
        }
        #endif
    }
}
