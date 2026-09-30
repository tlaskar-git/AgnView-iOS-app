import Foundation
import os

/// Debug logging for answers the app could not read. It records the key path
/// of the failure and never the body, so no hub data reaches the log.
enum HubLog {
    private static let logger = Logger(subsystem: "com.example.agnview", category: "decode")

    static func decodeFailure(_ type: Any.Type, _ error: Error) {
        let path: String
        if let decoding = error as? DecodingError {
            let keys: [CodingKey]
            switch decoding {
            case .typeMismatch(_, let context), .valueNotFound(_, let context),
                 .keyNotFound(_, let context), .dataCorrupted(let context):
                keys = context.codingPath
            @unknown default:
                keys = []
            }
            path = keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        } else {
            path = "not a decoding error"
        }
        logger.debug("decode failed for \(String(describing: type), privacy: .public) at key path \(path, privacy: .public)")
    }

    static func listFailure(_ type: Any.Type) {
        logger.debug("list not readable for \(String(describing: type), privacy: .public)")
    }

    private static let lifecycle = Logger(subsystem: "com.example.agnview", category: "lifecycle")

    /// One line about the connection or demo lifecycle: never hub data,
    /// never a prompt, only what happened and a counter.
    static func event(_ text: String) {
        lifecycle.info("\(text, privacy: .public)")
    }
}
