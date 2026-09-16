import Foundation
import SwiftUI

struct MeasuredRecord: Identifiable, Codable {
    let id = UUID(); var index: Int; var timestamp: Date; var value: Double; var alarm: Bool; var mode: Int; var period: Int
    enum CodingKeys: String, CodingKey { case index, timestamp, value, alarm, mode, period }
}

@MainActor final class AppModel: ObservableObject {
    @AppStorage("host") var host = "192.168.0.99"; @AppStorage("port") var port = 2500
    @AppStorage("bridgeHost") var bridgeHost = "178.17.15.192"; @AppStorage("bridgePort") var bridgePort = 2001
    @AppStorage("deviceID") var deviceID = ""; @AppStorage("rcLanguage") var rcLanguage = "English"
    @Published var connectionState = "Odpojeno"; @Published var status = "Připraveno"; @Published var isConnected = false
    @Published var pixels = Array(repeating: Color.black, count: 160 * 128); @Published var records: [MeasuredRecord] = []
    @Published var parameters = DeviceParameters(); @Published var firmware = "—"; @Published var serial = "—"
    @Published private(set) var parameterBounds = MiniEXParameterBounds.defaults
    private var firmwareVersion: MiniEXFirmwareVersion?
    private let transport: MiniEXTransport = TCPTransport(); private let decoder = PacketStreamDecoder()
    init() {
        transport.onState = { [weak self] value in Task { @MainActor in self?.connectionState = value; self?.isConnected = value == "Připojeno"; if value == "Připojeno" { self?.startRemote() } } }
        transport.onData = { [weak self] data in Task { @MainActor in self?.consume(data) } }
    }
    func connect(bridge: Bool = false) { transport.connect(host: bridge ? bridgeHost : host, port: UInt16(clamping: bridge ? bridgePort : port)) }
    func disconnect() { transport.disconnect() }
    func sendCM(_ id: UInt16, payload: Data = Data(), target: UInt8 = 5) { transport.send(PacketCodec.build(receiver: "a", sender: "b", id: id, payload: CMCodec.encode(target: target, source: 3, id: id, payload: payload))) }
    func startRemote() { sendCM(WireMessage.streamOn); sendCM(WireMessage.redraw) }
    func speed(down: Bool) { sendCM(down ? WireMessage.keyPress : WireMessage.keyRelease) }
    func refreshSettings() {
        let requests: [UInt16] = [
            WireMessage.getFirmware,
            WireMessage.getSerial,
            WireMessage.getLanguages,
            WireMessage.getBounds,
            WireMessage.getParameters
        ]
        requests.forEach { sendCM($0) }
        status = "Načítám nastavení…"
    }
    func saveSettings() {
        do {
            let wireValues = parameters.wireValues(bounds: parameterBounds)
            let payload = try MiniEXUserParametersCodec.encodeValues(wireValues, dataTypeSize: firmwareVersion?.dataTypeSize ?? 3)
            sendCM(WireMessage.setParameters, payload: payload)
            status = "Nastavení odesláno."
        } catch { status = error.localizedDescription }
    }
    func restoreDefaults() { sendCM(WireMessage.defaults); parameters = DeviceParameters(); status = "Výchozí nastavení vyžádáno." }
    func refreshData() { status = "Načítám data…"; sendCM(0x0B01); sendCM(0x0B06); sendCM(0x0501, target: 6) }
    func eraseData() { sendCM(0x0502, target: 6); records = []; status = "Požadavek na smazání odeslán." }
    func demo() {
        isConnected = false; connectionState = "Offline demo"; status = "Ukázkový obsah bez přístroje"
        let dark = Color(red: 0.04, green: 0.10, blue: 0.13)
        let light = Color(red: 0.08, green: 0.25, blue: 0.30)
        var demoPixels = Array(repeating: dark, count: 160 * 128)
        for pixelIndex in demoPixels.indices {
            let x = pixelIndex % 160
            let y = pixelIndex / 160
            demoPixels[pixelIndex] = (x / 10 + y / 8).isMultiple(of: 2) ? dark : light
        }
        pixels = demoPixels
        var demoRecords: [MeasuredRecord] = []
        let now = Date()
        for itemIndex in 0..<24 {
            let secondsAgo = TimeInterval(itemIndex * 60)
            let record = MeasuredRecord(
                index: itemIndex + 1,
                timestamp: now.addingTimeInterval(-secondsAgo),
                value: 0.12 + Double(itemIndex) * 0.018,
                alarm: itemIndex % 9 == 0,
                mode: itemIndex % 3,
                period: 60
            )
            demoRecords.append(record)
        }
        records = demoRecords
    }
    func exportTSV() -> URL? {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("miniEX-data.tsv")
        let df = ISO8601DateFormatter()
        var lines = ["Index\tTime\tValue\tAlarm\tMode\tPeriod"]
        for record in records {
            let alarmValue = record.alarm ? 1 : 0
            let timestamp = df.string(from: record.timestamp)
            lines.append("\(record.index)\t\(timestamp)\t\(record.value)\t\(alarmValue)\t\(record.mode)\t\(record.period)")
        }
        try? lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8); return f
    }
    private func consume(_ data: Data) { do { for packet in try decoder.append(data) { for message in try CMCodec.decodeAll(packet.payload) { handle(message) } } } catch { status = error.localizedDescription } }
    private func handle(_ m: CMMessage) {
        switch m.messageID {
        case WireMessage.getFirmware:
            firmwareVersion = try? MiniEXFirmwareVersion.decode(m.payload)
            if let version = firmwareVersion { firmware = "\(version.modelName), FW \(version.displayName)" }
        case WireMessage.getSerial where m.payload.count >= 4:
            var serialValue: UInt32 = 0
            for byteIndex in 0..<4 {
                serialValue |= UInt32(m.payload[byteIndex]) << UInt32(byteIndex * 8)
            }
            serial = String(serialValue)
        case WireMessage.getBounds:
            do { parameterBounds = try MiniEXUserParametersCodec.decodeBounds(m.payload); status = "Meze parametrů načteny." }
            catch { status = error.localizedDescription }
        case WireMessage.getParameters:
            do {
                let size = firmwareVersion?.dataTypeSize ?? 3
                let values = try MiniEXUserParametersCodec.decodeValues(m.payload, dataTypeSize: size).normalized(to: parameterBounds)
                parameters = DeviceParameters(wireValues: values, bounds: parameterBounds)
                status = "Nastavení načteno."
            } catch { status = error.localizedDescription }
        case WireMessage.stream: renderStream(m.payload)
        default: status = "Přijata zpráva 0x\(String(m.messageID, radix: 16))"
        }
    }
    private func renderStream(_ data: Data) { guard !data.isEmpty else { return }; for (i,b) in data.enumerated() { let p = (i * 31) % pixels.count; pixels[p] = b & 1 == 0 ? .cyan : .red }; objectWillChange.send() }
}

struct DeviceParameters {
    var wideZero = 1000.0, wideAlarm = 200.0, advancedZero = 1000.0, advancedAlarm = 200.0, tatpZero = 1000.0, tatpAlarm = 200.0
    var offTime = 600.0, sampling = 15.0, beep = 5.0, alarm = 5.0, irPower = 0.0; var wifi = false; var primaryLanguage = 1; var secondaryLanguage = 1; var mode = 0
    init() {}
    init(wireValues: MiniEXUserParameters, bounds: MiniEXParameterBounds) {
        let raw = wireValues.raw
        wideZero = MiniEXUserParametersCodec.rawToDisplay(parameter: 0, raw: raw[0], scale: bounds.rawScale(0))
        wideAlarm = MiniEXUserParametersCodec.rawToDisplay(parameter: 1, raw: raw[1], scale: bounds.rawScale(1))
        offTime = MiniEXUserParametersCodec.rawToDisplay(parameter: 2, raw: raw[2], scale: bounds.rawScale(2))
        sampling = MiniEXUserParametersCodec.rawToDisplay(parameter: 3, raw: raw[3], scale: bounds.rawScale(3))
        beep = Double(raw[4]); alarm = Double(raw[5]); irPower = Double(raw[7])
        advancedZero = MiniEXUserParametersCodec.rawToDisplay(parameter: 8, raw: raw[8], scale: bounds.rawScale(8))
        advancedAlarm = MiniEXUserParametersCodec.rawToDisplay(parameter: 9, raw: raw[9], scale: bounds.rawScale(9))
        tatpZero = MiniEXUserParametersCodec.rawToDisplay(parameter: 10, raw: raw[10], scale: bounds.rawScale(10))
        tatpAlarm = MiniEXUserParametersCodec.rawToDisplay(parameter: 11, raw: raw[11], scale: bounds.rawScale(11))
        let flags = raw[MiniEXUserParametersCodec.bitConfigIndex]
        wifi = flags & MiniEXUserParametersCodec.wifiMask != 0
        primaryLanguage = MiniEXUserParametersCodec.languageID(bitConfig: flags, primary: true)
        secondaryLanguage = MiniEXUserParametersCodec.languageID(bitConfig: flags, primary: false)
        mode = wireValues.modeIndex
    }
    func wireValues(bounds: MiniEXParameterBounds) -> MiniEXUserParameters {
        var raw = MiniEXUserParameters.defaults.raw
        let displays = [wideZero, wideAlarm, offTime, sampling, beep, alarm]
        for index in displays.indices { raw[index] = MiniEXUserParametersCodec.displayToRaw(parameter: index, display: displays[index], scale: bounds.rawScale(index)) }
        raw[7] = Int(irPower)
        raw[8] = MiniEXUserParametersCodec.displayToRaw(parameter: 8, display: advancedZero, scale: bounds.rawScale(8))
        raw[9] = MiniEXUserParametersCodec.displayToRaw(parameter: 9, display: advancedAlarm, scale: bounds.rawScale(9))
        raw[10] = MiniEXUserParametersCodec.displayToRaw(parameter: 10, display: tatpZero, scale: bounds.rawScale(10))
        raw[11] = MiniEXUserParametersCodec.displayToRaw(parameter: 11, display: tatpAlarm, scale: bounds.rawScale(11))
        var flags = wifi ? MiniEXUserParametersCodec.wifiMask : 0
        flags = MiniEXUserParametersCodec.withLanguageID(bitConfig: flags, primary: true, languageID: primaryLanguage)
        flags = MiniEXUserParametersCodec.withLanguageID(bitConfig: flags, primary: false, languageID: secondaryLanguage)
        flags = (flags & ~MiniEXUserParametersCodec.modeMask) | ((mode << MiniEXUserParametersCodec.modeShift) & MiniEXUserParametersCodec.modeMask)
        raw[MiniEXUserParametersCodec.bitConfigIndex] = flags
        return MiniEXUserParameters(raw: raw)
    }
}
