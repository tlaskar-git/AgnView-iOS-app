import Foundation

/// The hub HTTP paths the phone uses over the LAN.
enum HubPath {
    static let status = "/api/mobile/status"
    static let usageAccounts = "/api/usage/accounts"
    static let jobs = "/api/jobs"
    static let liveSessions = "/api/console/live-sessions"
    static let dispatch = "/api/console/dispatch"
    static let consoleLogs = "/api/console/logs"
    static let events = "/api/events"
}
