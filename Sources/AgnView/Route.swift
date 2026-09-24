import Foundation

/// How the app reaches the hub. Defined by the hub pairing document.
enum Route: String, CaseIterable, Equatable {
    case lan
    case direct
    case relay
    case offline

    var label: String {
        switch self {
        case .lan: return "LAN"
        case .direct: return "Direct"
        case .relay: return "Relay"
        case .offline: return "Offline"
        }
    }
}
