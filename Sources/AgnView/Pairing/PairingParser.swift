import Foundation

enum PairingParser {
    static let hubIdLength = 16
    static let keyLength = 32
    static let maxNameLength = 128
    static let maxTicketLength = 4096

    static func parse(_ text: String) throws -> PairingPayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { throw PairingError.malformedURL }
        return try parse(url)
    }

    static func parse(_ url: URL) throws -> PairingPayload {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PairingError.malformedURL
        }
        guard comps.scheme?.lowercased() == "agnview" else { throw PairingError.wrongScheme }
        guard comps.host?.lowercased() == "pair" else { throw PairingError.wrongHost }

        // First occurrence wins. Unknown fields are ignored.
        var fields: [String: String] = [:]
        for item in comps.queryItems ?? [] where fields[item.name] == nil {
            if let value = item.value { fields[item.name] = value }
        }

        guard let vText = fields["v"] else { throw PairingError.missingField("v") }
        guard let version = Int(vText), version == 1 || version == 2 else {
            throw PairingError.unsupportedVersion
        }

        guard let name = fields["name"], !name.isEmpty else { throw PairingError.missingField("name") }
        guard name.count <= maxNameLength, !containsControl(name) else { throw PairingError.invalidName }

        guard let lan = fields["lan"] else { throw PairingError.missingField("lan") }
        let (host, port) = try parseLAN(lan)

        guard let fp = fields["fp"] else { throw PairingError.missingField("fp") }
        guard fp.count == 64, fp.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw PairingError.invalidFingerprint
        }

        guard let idText = fields["id"] else { throw PairingError.missingField("id") }
        guard let hubId = Base64URL.decode(idText), hubId.count == hubIdLength else {
            throw PairingError.invalidHubId
        }

        guard let kText = fields["k"] else { throw PairingError.missingField("k") }
        guard let key = Base64URL.decode(kText), key.count == keyLength else {
            throw PairingError.invalidKey
        }

        // iroh is a v2 field. A v1 payload never carries one, so it is ignored there.
        var ticket: String?
        if version == 2, let raw = fields["iroh"] {
            guard !raw.isEmpty, raw.count <= maxTicketLength, !containsControl(raw),
                  !raw.contains(where: { $0.isWhitespace }) else {
                throw PairingError.invalidIrohTicket
            }
            ticket = raw
        }

        return PairingPayload(version: version, name: name, lanHost: host, lanPort: port,
                              fingerprint: fp.lowercased(), hubId: hubId, key: key, irohTicket: ticket)
    }

    private static func containsControl(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// host:port. Host is an IPv4 address in RFC 1918 space or 127.0.0.1.
    /// The TEST-NET-1 documentation block is also accepted so fixtures and examples work.
    private static func parseLAN(_ text: String) throws -> (String, Int) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw PairingError.invalidLAN }
        let host = String(parts[0])
        guard let octets = ipv4Octets(host), isAllowedHost(octets) else { throw PairingError.invalidLAN }
        let portText = parts[1]
        guard !portText.isEmpty, portText.count <= 5, portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(portText), (1...65535).contains(port) else {
            throw PairingError.invalidLAN
        }
        return (host, port)
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(p), n <= 255 else { return nil }
            // No leading zeros, so the text form is canonical.
            if p.count > 1 && p.first == "0" { return nil }
            out.append(n)
        }
        return out
    }

    private static func isAllowedHost(_ o: [Int]) -> Bool {
        if o == [127, 0, 0, 1] { return true }
        if o[0] == 10 { return true }
        if o[0] == 172 && (16...31).contains(o[1]) { return true }
        if o[0] == 192 && o[1] == 168 { return true }
        if o[0] == 192 && o[1] == 0 && o[2] == 2 { return true }
        return false
    }
}
