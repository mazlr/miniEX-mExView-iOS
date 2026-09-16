import Foundation

enum OfflineRecording: String, CaseIterable, Identifiable {
    case short = "RC-short"
    case long = "RC-long"

    var id: String { rawValue }
    var title: String { self == .short ? "Short recording (65 frames)" : "Long recording (695 frames)" }
}

struct OfflineRCFrame {
    let sequence: UInt16
    let commands: [RCCommand]
}

enum OfflineReplay {
    static func load(_ recording: OfflineRecording, bundle: Bundle = .main) throws -> [OfflineRCFrame] {
        guard let url = bundle.url(forResource: recording.rawValue, withExtension: "txt") else {
            throw CodecError.malformed("Chybí záznam \(recording.rawValue).txt v aplikaci.")
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let decoder = PacketStreamDecoder()
        var frames: [OfflineRCFrame] = []
        for (lineNumber, source) in contents.split(whereSeparator: \.isNewline).enumerated() {
            let line = String(source).trimmingCharacters(in: .whitespaces)
            let packetText = line.hasPrefix("~") ? String(line.dropFirst()) : line
            guard !packetText.isEmpty else { continue }
            do {
                for packet in try decoder.append(Data(packetText.utf8)) {
                    for message in try CMCodec.decodeAll(packet.payload)
                    where message.targetPID == 5 && message.sourcePID == 1 && message.messageID == WireMessage.stream {
                        let (sequence, commands) = try RCStream.decode(message.payload)
                        frames.append(OfflineRCFrame(sequence: sequence, commands: commands))
                    }
                }
            } catch {
                throw CodecError.malformed("Záznam \(recording.rawValue), řádek \(lineNumber + 1): \(error.localizedDescription)")
            }
        }
        guard !frames.isEmpty else { throw CodecError.malformed("Záznam neobsahuje žádné RC rámce.") }
        return frames
    }
}
