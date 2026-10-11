import Foundation

/// Message types on the wire. See ../../PROTOCOL.md.
enum MessageType: UInt8 {
    case hello = 0x01
    case videoConfig = 0x02
    case videoFrame = 0x03
    case audioConfig = 0x04
    case audioFrame = 0x05
    case helloAck = 0x10
    case requestKeyframe = 0x11
}

struct MessageFlags: OptionSet {
    let rawValue: UInt8
    static let keyframe = MessageFlags(rawValue: 1 << 0)
}

struct MessageHeader {
    let type: UInt8
    let flags: UInt8
    let ptsMicros: UInt64
    let payloadLength: Int
}

struct HelloInfo: Codable {
    var v: Int = WireProtocol.version
    var name: String
    var width: Int
    var height: Int
    var fps: Int
    var codec: String = "h264"
}

enum WireProtocol {
    static let version = 1
    static let headerSize = 16
    static let maxPayload = 16 * 1024 * 1024
    static let serviceType = "_mactvmirror._tcp"
    static let defaultPort: UInt16 = 7000

    static func encode(type: MessageType, flags: MessageFlags = [], ptsMicros: UInt64 = 0, payload: Data = Data()) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        out.append(type.rawValue)
        out.append(flags.rawValue)
        out.append(contentsOf: [0, 0])
        var pts = ptsMicros.bigEndian
        withUnsafeBytes(of: &pts) { out.append(contentsOf: $0) }
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    static func parseHeader(_ bytes: Data) -> MessageHeader? {
        guard bytes.count >= headerSize else { return nil }
        let b = [UInt8](bytes.prefix(headerSize))
        var pts: UInt64 = 0
        for i in 4..<12 { pts = (pts << 8) | UInt64(b[i]) }
        var length: UInt32 = 0
        for i in 12..<16 { length = (length << 8) | UInt32(b[i]) }
        return MessageHeader(type: b[0], flags: b[1], ptsMicros: pts, payloadLength: Int(length))
    }
}

/// Incremental parser for the receiver → sender control channel.
struct MessageReader {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [(MessageHeader, Data)] {
        buffer.append(data)
        var out: [(MessageHeader, Data)] = []
        while let header = WireProtocol.parseHeader(buffer) {
            guard header.payloadLength <= WireProtocol.maxPayload else {
                Log.warn("control channel: oversized message, resetting parser")
                buffer = Data()
                break
            }
            let total = WireProtocol.headerSize + header.payloadLength
            guard buffer.count >= total else { break }
            let payload = buffer.subdata(in: WireProtocol.headerSize..<total)
            out.append((header, payload))
            buffer = buffer.subdata(in: total..<buffer.count)
        }
        return out
    }
}
