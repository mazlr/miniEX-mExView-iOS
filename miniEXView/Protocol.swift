import Foundation

enum CodecError: LocalizedError {
    case malformed(String)
    var errorDescription: String? { if case .malformed(let s) = self { return s }; return nil }
}

enum AlphaHex {
    static func encode(_ bytes: Data) -> String {
        bytes.flatMap { [Character(UnicodeScalar(65 + Int($0 >> 4))!), Character(UnicodeScalar(65 + Int($0 & 15))!)] }.reduce("") { $0 + String($1) }
    }
    static func encode(_ value: Int, digits: Int) -> String {
        precondition(value >= 0 && digits > 0 && digits <= 8)
        return stride(from: (digits - 1) * 4, through: 0, by: -4).map { String(UnicodeScalar(65 + ((value >> $0) & 15))!) }.joined()
    }
    static func decode(_ text: Substring) throws -> Int {
        guard !text.isEmpty, text.count <= 8 else { throw CodecError.malformed("Neplatná délka AlphaHex.") }
        return try text.reduce(0) { result, c in
            guard let a = c.asciiValue, a >= 65, a <= 80 else { throw CodecError.malformed("Neplatný znak AlphaHex: \(c)") }
            return (result << 4) | Int(a - 65)
        }
    }
    static func data(_ text: Substring) throws -> Data {
        guard text.count.isMultiple(of: 2) else { throw CodecError.malformed("AlphaHex data nemají sudou délku.") }
        var result = Data(); var i = text.startIndex
        while i < text.endIndex { let j = text.index(i, offsetBy: 2); result.append(UInt8(try decode(text[i..<j]))); i = j }
        return result
    }
}

struct MiniEXPacket: Equatable { let type: Character; let receiver: Character; let sender: Character; let id: UInt16; let payload: Data }

enum PacketCodec {
    static func build(type: Character = "0", receiver: Character = "0", sender: Character = "2", id: UInt16, payload: Data) -> Data {
        precondition(payload.count <= 255)
        let head = "#\(type)\(receiver)\(sender) \(AlphaHex.encode(Int(id), digits: 4)) \(AlphaHex.encode(payload.count, digits: 2)) "
        var body = Data(head.utf8); body.append(payload)
        let checksum = body.dropFirst().reduce(0) { ($0 + Int($1)) & 0xffff }
        body.append(contentsOf: AlphaHex.encode(checksum, digits: 4).utf8)
        return body
    }
}

final class PacketStreamDecoder {
    private var buffer = Data()
    func reset() { buffer.removeAll(keepingCapacity: true) }
    func append(_ bytes: Data) throws -> [MiniEXPacket] {
        buffer.append(bytes); var packets: [MiniEXPacket] = []
        while let marker = buffer.firstIndex(of: 35) {
            if marker > 0 { buffer.removeFirst(marker) }
            guard buffer.count >= 13 else { break }
            guard let text = String(data: buffer.prefix(13), encoding: .ascii) else { buffer.removeFirst(); continue }
            let chars = Array(text); guard chars[4] == " ", chars[9] == " ", chars[12] == " " else { buffer.removeFirst(); continue }
            let length = try AlphaHex.decode(text[text.index(text.startIndex, offsetBy: 10)..<text.index(text.startIndex, offsetBy: 12)])
            let total = 13 + length + 4; guard buffer.count >= total else { break }
            let raw = buffer.prefix(total), expected = try AlphaHex.decode(Substring(String(decoding: raw.suffix(4), as: UTF8.self)))
            let actual = raw.dropFirst().dropLast(4).reduce(0) { ($0 + Int($1)) & 0xffff }
            guard actual == expected else { buffer.removeFirst(); throw CodecError.malformed("Nesouhlasí checksum paketu.") }
            let id = try AlphaHex.decode(text[text.index(text.startIndex, offsetBy: 5)..<text.index(text.startIndex, offsetBy: 9)])
            packets.append(.init(type: chars[1], receiver: chars[2], sender: chars[3], id: UInt16(id), payload: Data(raw.dropFirst(13).dropLast(4))))
            buffer.removeFirst(total)
        }
        return packets
    }
}

struct CMMessage { let targetPID, sourcePID, flags: UInt8; let messageID: UInt16; let payload: Data }
enum CMCodec {
    static func encode(target: UInt8, source: UInt8, flags: UInt8 = 0, id: UInt16, payload: Data = Data()) -> Data {
        var bytes = Data([target, source, flags, UInt8(id & 255), UInt8(id >> 8)]); bytes.append(payload)
        return Data(("*a" + AlphaHex.encode(payload.count, digits: 2) + AlphaHex.encode(bytes)).utf8)
    }
    static func decodeAll(_ data: Data) throws -> [CMMessage] {
        guard let text = String(data: data, encoding: .ascii) else { throw CodecError.malformed("CM paket není ASCII.") }
        var out: [CMMessage] = []; var p = text.startIndex
        while let r = text.range(of: "*a", range: p..<text.endIndex) {
            let lenStart = r.upperBound
            guard let lenEnd = text.index(lenStart, offsetBy: 2, limitedBy: text.endIndex) else { throw CodecError.malformed("Neúplná délka CM zprávy.") }
            let n = try AlphaHex.decode(text[lenStart..<lenEnd])
            guard let end = text.index(lenEnd, offsetBy: 10 + n * 2, limitedBy: text.endIndex) else { throw CodecError.malformed("Neúplná CM zpráva.") }
            let raw = try AlphaHex.data(text[lenEnd..<end]); guard raw.count == n + 5 else { throw CodecError.malformed("Chybná délka CM zprávy.") }
            out.append(.init(targetPID: raw[0], sourcePID: raw[1], flags: raw[2], messageID: UInt16(raw[3]) | UInt16(raw[4]) << 8, payload: raw.dropFirst(5)))
            p = end
        }
        return out
    }
}

enum WireMessage {
    static let stream: UInt16 = 0x0240, streamOn: UInt16 = 0x0241, streamOff: UInt16 = 0x0242
    static let keyPress: UInt16 = 0x0301, keyRelease: UInt16 = 0x0302, redraw: UInt16 = 0x0610
    static let getSerial: UInt16 = 0x0B05, getFirmware: UInt16 = 0x0B06, getLanguages: UInt16 = 0x0B09
    static let getBounds: UInt16 = 0x0520, getParameters: UInt16 = 0x0521, setParameters: UInt16 = 0x0522, defaults: UInt16 = 0x0523
}
