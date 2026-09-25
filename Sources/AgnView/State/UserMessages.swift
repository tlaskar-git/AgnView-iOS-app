import Foundation

/// Every user-facing state message. Screens show these strings unchanged.
enum UserMessages {
    static let pairedWithoutLANBanner = "This pairing has no local network address. In AgnView, turn on Allow phones on my network, then scan the pairing QR code again."
    static let notOnSameNetworkBanner = "Not on the same Wi-Fi as your computer. Console works over iroh. Prompts, Usage and Pipelines need the same Wi-Fi."
    static let authFailed = "The hub rejected this pairing. Scan the QR code again."
    static let keyRevoked = "The key was regenerated on the hub. Re-pair to continue."
    static let removedFromPhone = "Removed from this phone. The key stays valid on the hub until you regenerate it there."
    static let sessionsFromLog = "Showing sessions seen in the log stream"
    static let hubNeedsUpdate = "Your hub does not support remote access yet. Update AgnView on your computer to 0.1.12 or later."
    static let offlineHub = "Can't reach this hub. Check that AgnView is running on your computer."

    static func lanBanner(_ reason: LANUnavailableReason) -> String {
        switch reason {
        case .pairedWithoutLAN: return pairedWithoutLANBanner
        case .notOnSameNetwork: return notOnSameNetworkBanner
        }
    }
}

/// Why the LAN route is not carrying the session while iroh is.
enum LANUnavailableReason: Equatable {
    /// The stored pairing has a loopback address, so LAN was never tried.
    case pairedWithoutLAN
    /// The pairing has a real LAN address but the phone could not reach it.
    case notOnSameNetwork
}
