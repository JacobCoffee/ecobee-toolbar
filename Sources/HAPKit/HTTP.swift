import Foundation

public struct HTTPMessage: Sendable {
    /// "HTTP/1.1" for responses, "EVENT/1.0" for HAP notifications.
    public let version: String
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public var isEvent: Bool { version.hasPrefix("EVENT") }
}

enum HTTPRequest {
    static func encode(method: String, path: String, body: Data? = nil, contentType: String? = nil) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: hap.local\r\n"
        if let body {
            head += "Content-Type: \(contentType ?? "application/hap+json")\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + (body ?? Data())
    }
}

/// Incremental parser for HTTP/1.1 responses and EVENT/1.0 messages.
struct HTTPParser {
    private var buffer = Data()

    mutating func append(_ data: Data) { buffer += data }

    /// Returns the next complete message, or nil if more bytes are needed.
    mutating func next() throws -> HTTPMessage? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headText = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw HAPError.malformedHTTP
        }
        let lines = headText.components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { throw HAPError.malformedHTTP }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = headerEnd.upperBound
        let body: Data
        let consumed: Int
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (decoded, end) = try Self.dechunk(buffer, from: bodyStart) else { return nil }
            body = decoded
            consumed = end
        } else if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard buffer.endIndex - bodyStart >= length else { return nil }
            body = Data(buffer[bodyStart..<bodyStart + length])
            consumed = bodyStart + length
        } else {
            body = Data()
            consumed = bodyStart
        }
        buffer = Data(buffer[consumed...])
        return HTTPMessage(version: String(statusParts[0]), status: status, headers: headers, body: body)
    }

    private static func dechunk(_ data: Data, from start: Int) throws -> (Data, Int)? {
        var body = Data()
        var index = start
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText.split(separator: ";")[0].trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw HAPError.malformedHTTP
            }
            let chunkStart = lineEnd.upperBound
            guard data.endIndex - chunkStart >= size + 2 else { return nil }
            if size == 0 { return (body, chunkStart + 2) }
            body += data[chunkStart..<chunkStart + size]
            index = chunkStart + size + 2
        }
    }
}
