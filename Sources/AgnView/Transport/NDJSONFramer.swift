import Foundation

/// Splits a byte stream into newline-delimited lines.
///
/// Feed it chunks of any size. It returns every complete line, without the
/// line ending. A trailing CR is removed, so CRLF works. Empty lines are
/// dropped. A line longer than `maxLineLength` is a protocol violation.
struct NDJSONFramer {
    static let defaultMaxLineLength = 1 << 20

    let maxLineLength: Int
    private var buffer = Data()

    init(maxLineLength: Int = NDJSONFramer.defaultMaxLineLength) {
        self.maxLineLength = maxLineLength
    }

    /// Bytes held for a line that is not complete yet.
    var pendingByteCount: Int { buffer.count }

    mutating func feed(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in chunk {
            if byte == 0x0A {
                if let line = takeLine() { lines.append(line) }
                continue
            }
            buffer.append(byte)
            if buffer.count > maxLineLength {
                buffer.removeAll(keepingCapacity: false)
                throw TransportError.protocolViolation
            }
        }
        return lines
    }

    /// Returns the last line when the stream ended without a newline.
    mutating func finish() -> Data? {
        takeLine()
    }

    private mutating func takeLine() -> Data? {
        var line = buffer
        buffer = Data()
        if line.last == 0x0D { line.removeLast() }
        return line.isEmpty ? nil : line
    }
}
