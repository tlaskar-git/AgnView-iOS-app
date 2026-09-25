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
    static let capabilities = "/api/system/capabilities"
    static let files = "/api/system/files"
    static let usageRefreshAll = "/api/usage/refresh-all"

    static func job(_ id: String) -> String { jobs + "/" + id }
    static func requestRevision(task id: String) -> String { "/api/tasks/" + id + "/request-revision" }
    static func failTask(_ id: String) -> String { "/api/tasks/" + id + "/fail" }
}
