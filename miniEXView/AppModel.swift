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
    @Published var pixels = Array(repeating: Color.black, count: 160 * 128); @Published var displayImage: UIImage?; @Published var remoteActive = false; @Published var records: [MeasuredRecord] = []
    @Published var parameters = DeviceParameters(); @Published var firmware = "—"; @Published var serial = "—"
    @Published private(set) var diagnosticLines: [String] = []
    @Published private(set) var bytesSent = 0
    @Published private(set) var bytesQueued = 0
    @Published private(set) var bytesReceived = 0
    @Published private(set) var packetCount = 0
    @Published private(set) var cmMessageCount = 0
    @Published private(set) var parameterBounds = MiniEXParameterBounds.defaults
    private var firmwareVersion: MiniEXFirmwareVersion?
    private var nextPacketID: UInt16 = 0
    private var deviceKeyHeld = false
    private var connectedEndpoint = "—"
    private let transport: MiniEXTransport = TCPTransport(); private let decoder = PacketStreamDecoder()
    private let log = DiagnosticLog()
    private var display: RCDisplay?
    var diagnosticFileURL: URL { log.url }
    init() {
        do { display = RCDisplay(resources: try RCResources.load()); displayImage = display?.image() }
        catch { appendDiagnostic("RC RESOURCES ERROR: \(error)") }
        appendDiagnostic("Aplikace spuštěna, verze \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        transport.onRawData = { [log] data in log.rawTCP(data) }
        transport.onState = { [weak self] value in Task { @MainActor in
            guard let self else { return }
            self.connectionState = value; self.isConnected = value == "Připojeno"
            self.appendDiagnostic("SOCKET: \(value)")
            if value != "Připojeno" {
                self.remoteActive = false
                self.status = value
                if self.deviceKeyHeld { self.deviceKeyHeld = false; self.appendDiagnostic("RC KEY: spojení skončilo během stisku") }
            }
        } }
        transport.onWrite = { [weak self] count, error in Task { @MainActor in
            guard let self else { return }
            if let error { self.appendDiagnostic("TX ERROR: \(count) B: \(error)"); self.status = error }
            else { self.bytesSent += count; self.appendDiagnostic("TX COMPLETE: \(count) B předáno TCP stacku (odpověď přístroje se ověřuje zvlášť)") }
        } }
        transport.onData = { [weak self] data in Task { @MainActor in
            guard let self else { return }
            self.bytesReceived += data.count
            self.appendDiagnostic("RX TCP: \(data.count) B")
            self.appendDiagnostic("RX CHUNK ASCII: \(String(decoding: data, as: UTF8.self))")
            self.appendDiagnostic("RX CHUNK HEX: \(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            self.consume(data)
        } }
    }
    func connect(bridge: Bool = false) {
        let selectedHost = bridge ? bridgeHost : host; let selectedPort = UInt16(clamping: bridge ? bridgePort : port)
        guard !selectedHost.isEmpty, selectedPort > 0 else { appendDiagnostic("CONNECT ERROR: neplatný host nebo port"); return }
        releaseDeviceKey()
        decoder.reset()
        connectedEndpoint = "\(selectedHost):\(selectedPort)"
        appendDiagnostic("CONNECT: \(selectedHost):\(selectedPort) režim=\(bridge ? "bridge" : "Wi-Fi")")
        transport.connect(host: selectedHost, port: selectedPort)
    }
    func disconnect() { releaseDeviceKey(); appendDiagnostic("DISCONNECT: požadavek uživatele"); transport.disconnect() }
    var activeEndpoint: String { connectedEndpoint }
    func sendCM(_ id: UInt16, payload: Data = Data(), target: UInt8, source: UInt8 = 5, flags: UInt8 = 0x20) {
        guard isConnected else { appendDiagnostic("TX SKIPPED: socket není připraven, CM=0x\(String(format: "%04X", id))"); return }
        let cm = CMCodec.encode(target: target, source: source, flags: flags, id: id, payload: payload)
        let packetID = nextPacketID
        nextPacketID &+= 1
        let packet = PacketCodec.build(id: packetID, payload: cm)
        bytesQueued += packet.count
        appendDiagnostic("TX PACKET: #002 id=0x\(String(format: "%04X", packetID)) len=\(cm.count) B checksum=\(String(decoding: packet.suffix(4), as: UTF8.self))")
        appendDiagnostic("TX CM: target=0x\(String(format: "%02X", target)) source=0x\(String(format: "%02X", source)) flags=0x\(String(format: "%02X", flags)) id=0x\(String(format: "%04X", id)) data=\(payload.count) B")
        appendDiagnostic("TX ASCII: \(String(decoding: packet, as: UTF8.self))")
        appendDiagnostic("TX HEX: \(packet.map { String(format: "%02X", $0) }.joined(separator: " "))")
        transport.send(packet)
    }
    func startRemote() {
        guard isConnected else { return }
        // Android MiniExProtocol.remoteOn(): retries=0, timeout=500 ms, little endian.
        sendCM(WireMessage.streamOn, payload: Data([0, 0, 0xf4, 0x01]), target: 1, flags: 0)
        sendCM(WireMessage.redraw, target: 2)
        remoteActive = true
        appendDiagnostic("RC ON: aktivace vyžádána")
    }
    func stopRemote() {
        guard isConnected else { return }
        releaseDeviceKey()
        sendCM(WireMessage.streamOff, target: 1, flags: 0)
        remoteActive = false
        appendDiagnostic("RC OFF: deaktivace vyžádána")
    }
    func toggleRemote() { remoteActive ? stopRemote() : startRemote() }
    func pressDeviceKey() {
        guard isConnected, !deviceKeyHeld else { return }
        deviceKeyHeld = true
        sendCM(WireMessage.keyPress, target: 6)
    }
    func releaseDeviceKey() {
        guard deviceKeyHeld else { return }
        deviceKeyHeld = false
        sendCM(WireMessage.keyRelease, target: 6)
    }
    func refreshSettings() {
        let requests: [UInt16] = [
            WireMessage.getFirmware,
            WireMessage.getSerial,
            WireMessage.getLanguages,
            WireMessage.getBounds,
            WireMessage.getParameters
        ]
        for request in requests {
            let target: UInt8 = request == WireMessage.getBounds || request == WireMessage.getParameters ? 5 : 7
            sendCM(request, target: target, source: 3, flags: 0)
        }
        status = "Načítám nastavení…"
    }
    func saveSettings() {
        do {
            let wireValues = parameters.wireValues(bounds: parameterBounds)
            let payload = try MiniEXUserParametersCodec.encodeValues(wireValues, dataTypeSize: firmwareVersion?.dataTypeSize ?? 3)
            sendCM(WireMessage.setParameters, payload: payload, target: 5, source: 3, flags: 0)
            status = "Nastavení odesláno."
        } catch { status = error.localizedDescription }
    }
    func restoreDefaults() { sendCM(WireMessage.defaults, target: 5, source: 3, flags: 0); parameters = DeviceParameters(); status = "Výchozí nastavení vyžádáno." }
    func refreshData() { status = "Načítám data…"; sendCM(0x0B01, target: 7, source: 3, flags: 0); sendCM(0x0B06, target: 7, source: 3, flags: 0); sendCM(0x0501, target: 5, source: 3, flags: 0) }
    func eraseData() { sendCM(0x0502, target: 5, source: 3, flags: 0); status = "Požadavek na smazání odeslán." }
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
        pixels = demoPixels; displayImage = nil
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
    func clearDiagnostics() { diagnosticLines.removeAll(); bytesSent = 0; bytesQueued = 0; bytesReceived = 0; packetCount = 0; cmMessageCount = 0; appendDiagnostic("Diagnostika vymazána") }
    var diagnosticText: String { diagnosticLines.joined(separator: "\n") }
    private func consume(_ data: Data) {
        do {
            for packet in try decoder.append(data) {
                packetCount += 1
                appendDiagnostic("RX PACKET: type=\(packet.type) to=\(packet.receiver) from=\(packet.sender) id=0x\(String(format: "%04X", packet.id)) data=\(packet.payload.count) B")
                appendDiagnostic("RX ASCII: \(String(decoding: packet.payload, as: UTF8.self))")
                for message in try CMCodec.decodeAll(packet.payload) {
                    cmMessageCount += 1
                    appendDiagnostic("RX CM: id=0x\(String(format: "%04X", message.messageID)) source=\(message.sourcePID) flags=0x\(String(format: "%02X", message.flags)) data=\(message.payload.count) B")
                    if message.targetPID == 5, message.sourcePID == 1, message.messageID == WireMessage.stream, message.payload.count >= 2 {
                        let sequence = Data(message.payload.prefix(2))
                        sendCM(WireMessage.stream, payload: sequence, target: 1)
                        do {
                            let (_, commands) = try RCStream.decode(message.payload)
                            display?.apply(commands)
                            displayImage = display?.image()
                            appendDiagnostic("RX RC: seq=\(UInt16(sequence[0]) | UInt16(sequence[1]) << 8), commands=\(commands.count), ACK")
                        } catch { appendDiagnostic("RC DECODE ERROR: \(error.localizedDescription)") }
                    }
                    if message.targetPID == 5, message.sourcePID == 1, message.messageID == WireMessage.streamOff, message.flags & 0x40 != 0 {
                        appendDiagnostic("RC OFF ANSWER: \(message.flags & 0x80 == 0 ? "OK" : "ERROR")")
                    }
                    handle(message)
                }
            }
        } catch { status = error.localizedDescription; appendDiagnostic("DECODE ERROR: \(error.localizedDescription)") }
    }
    private func appendDiagnostic(_ text: String) {
        log.write(text)
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
        diagnosticLines.append("[\(formatter.string(from: Date()))] \(text)")
        if diagnosticLines.count > 500 { diagnosticLines.removeFirst(diagnosticLines.count - 500) }
    }
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
        case WireMessage.stream, WireMessage.streamOff: break
        default: status = "Přijata zpráva 0x\(String(m.messageID, radix: 16))"
        }
    }
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
