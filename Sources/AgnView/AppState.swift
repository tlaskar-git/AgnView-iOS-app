import Foundation

#if DEBUG
/// Debug-only test hub support. Release builds never read the variable.
enum MockHub {
    /// The key the mock hub accepts. AGNVIEW_E2E_KEY replaces it when a test
    /// run points the app at a real hub. The value is never printed or stored.
    static let pairingKey: String = {
        let value = ProcessInfo.processInfo.environment["AGNVIEW_E2E_KEY"] ?? ""
        return value.isEmpty ? "test-key-not-real" : value
    }()

    static var baseURL: URL? {
        guard let value = ProcessInfo.processInfo.environment["AGNVIEW_MOCK_HUB_URL"],
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    static func get(_ path: String, base: URL) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue(pairingKey, forHTTPHeaderField: "X-AgnView-Token")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
#endif

// The app state lives in State/AppModel.swift. This file keeps the debug
// mock hub constants only.
