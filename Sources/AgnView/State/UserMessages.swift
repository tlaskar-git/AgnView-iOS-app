import Foundation

/// Every user-facing state message. Screens show these strings unchanged.
enum UserMessages {
    static let dispatchNeedsLAN = "Sending prompts needs your local network. Turn on Allow phones on my network in AgnView and join the same Wi-Fi."
    static let relayOnlyBanner = "Connected through iroh only. Allow phones on my network is off on the hub."
    static let authFailed = "The hub rejected this pairing. Scan the QR code again."
    static let keyRevoked = "The key was regenerated on the hub. Re-pair to continue."
    static let removedFromPhone = "Removed from this phone. The key stays valid on the hub until you regenerate it there."
    static let sessionsFromLog = "Showing sessions seen in the log stream"
    static let offlineHub = "Can't reach this hub. Check that AgnView is running on your computer."
    static let usageNeedsLAN = "Usage needs your local network."
    static let jobsNeedsLAN = "Pipelines need your local network."
}
