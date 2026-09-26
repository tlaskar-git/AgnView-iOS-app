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
    /// A hub that serves the mobile API over iroh but does not list "uploads"
    /// in its hello: hub 0.1.12, or a newer hub with iroh uploads turned off.
    static let needsSameWiFi = "Creating pipelines away from your Wi-Fi needs AgnView 0.1.13 or later on your computer, with phone uploads over iroh turned on. On the same Wi-Fi it works now."
    /// The attach picker over iroh: the hub lists its files on the LAN only.
    static let computerFilesNeedSameWiFi = "Files on your computer can be listed on the same Wi-Fi as your computer only."
    /// The Model menu over iroh before the phone has ever read the hub's list.
    static let modelsNeedSameWiFi = "The model list loads the first time you connect on the same Wi-Fi as your computer. Default lets the hub pick."
    /// The Model menu for an agent the hub lists no models for.
    static let noNamedModels = "The hub lists no models for this agent. Default lets the hub pick."
    /// The banner every screen shows while the demo runs.
    static let demoBanner = "Demo mode. Sample data only. Nothing is connected."
    static let demoStatus = "Demo computer is healthy"
    static let demoRouteLabel = "Demo"
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
