import Foundation

/// Decoded contents of an agnview://pair link (payload v1 or v2).
/// The key is secret. Never log a payload or any value derived from it.
struct PairingPayload: Equatable, Sendable {
    let version: Int
    let name: String
    let lanHost: String
    let lanPort: Int
    let fingerprint: String
    let hubId: Data
    let key: Data
    let irohTicket: String?

    /// True when the hub advertises no LAN rung (127.0.0.1). The client goes straight to iroh.
    var isLoopbackLAN: Bool { lanHost == "127.0.0.1" }

    /// Stable string form of the hub id (base64url, no padding). Used as the Keychain account and record id.
    var hubIdString: String { Base64URL.encode(hubId) }
}

/// Parse failures. Cases carry no payload text, so a description never leaks the key.
enum PairingError: Error, Equatable {
    case malformedURL
    case wrongScheme
    case wrongHost
    case unsupportedVersion
    case missingField(String)
    case invalidName
    case invalidLAN
    case invalidFingerprint
    case invalidHubId
    case invalidKey
    case invalidIrohTicket

    /// Stable machine-readable code.
    var code: String {
        switch self {
        case .malformedURL: return "malformed_url"
        case .wrongScheme: return "wrong_scheme"
        case .wrongHost: return "wrong_host"
        case .unsupportedVersion: return "unsupported_version"
        case .missingField(let f): return "missing_\(f)"
        case .invalidName: return "invalid_name"
        case .invalidLAN: return "invalid_lan"
        case .invalidFingerprint: return "invalid_fp"
        case .invalidHubId: return "invalid_id"
        case .invalidKey: return "invalid_key"
        case .invalidIrohTicket: return "invalid_iroh"
        }
    }

    /// Message safe to show in the UI.
    var userMessage: String {
        switch self {
        case .wrongScheme, .wrongHost, .malformedURL:
            return "This is not an AgnView pairing link."
        case .unsupportedVersion:
            return "This pairing link needs a newer version of AgnView."
        default:
            return "The pairing link is incomplete or damaged. Show a fresh QR code on your computer."
        }
    }
}

extension PairingError: CustomStringConvertible {
    var description: String { "PairingError(\(code))" }
}

enum Base64URL {
    private static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    /// Strict decode. Accepts the base64url alphabet only, with optional trailing "=" padding.
    static func decode(_ text: String) -> Data? {
        var body = Substring(text)
        while body.last == "=" { body = body.dropLast() }
        guard !body.isEmpty, body.allSatisfy({ alphabet.contains($0) }) else { return nil }
        var s = String(body).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch s.count % 4 {
        case 0: break
        case 2: s += "=="
        case 3: s += "="
        default: return nil
        }
        return Data(base64Encoded: s)
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
