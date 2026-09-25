import Foundation

/// Adapter for SwiftUI onOpenURL. Returns a result and never logs the URL.
struct PairingURLHandler {
    init() {}

    func handle(_ url: URL) -> Result<PairingPayload, PairingError> {
        do {
            return .success(try PairingParser.parse(url))
        } catch let error as PairingError {
            return .failure(error)
        } catch {
            return .failure(.malformedURL)
        }
    }
}
