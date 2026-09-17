import Foundation
import SwiftUI
import NetworkExtension

struct MeasuredRecord: Identifiable, Codable {
    let id = UUID(); var index: Int; var timestamp: Date; var value: Double; var alarm: Bool; var mode: Int; var period: Int
    enum CodingKeys: String, CodingKey { case index, timestamp, value, alarm, mode, period }
}

@MainActor final class AppModel: ObservableObject {
    @AppStorage("host") var host = "192.168.0.99"; @AppStorage("port") var port = 2500
    @AppStorage("bridgeHost") var bridgeHost = "178.17.15.192"; @AppStorage("bridgePort") var bridgePort = 2001
    @AppStorage("deviceID") var deviceID = ""; @AppStorage("rcLanguage") var rcLanguage = "English"
    @Published var connectionState = "Disconnected"; @Published var status = "Ready"; @Published var isConnected = false
    @Published var pixels = Array(repeating: Color.black, count: 160 * 128); @Published var displayImage: UIImage?; @Published var remoteActive = false; @Published var records: [MeasuredRecord] = []
    @Published private(set) var deviceSupportsRemote = false
    var canUseRemote: Bool { isConnected && deviceSupportsRemote }
    @Published var parameters = DeviceParameters(); @Published var firmware = "—"; @Published var serial = "—"
    @Published private(set) var diagnosticLines: [String] = []
    @Published private(set) var bytesSent = 0
    @Published private(set) var bytesQueued = 0
    @Published private(set) var bytesReceived = 0
    @Published private(set) var packetCount = 0
    @Published private(set) var cmMessageCount = 0
    @Published private(set) var isOfflineDemo = false
    @Published private(set) var replayPlaying = false
    @Published private(set) var replayProgress = 0
    @Published private(set) var replayTotal = 0
    @Published private(set) var parameterBounds = MiniEXParameterBounds.defaults
    private var firmwareVersion: MiniEXFirmwareVersion?
    private var detectingDevice = false
    private var detectionGeneration = 0
    private var settingsReadRequested = false
    @Published private(set) var supportedLanguages = [0, 1]
    @Published private(set) var supportedLanguageNames = ["Default (English)", "English"]
    func languageName(_ compactID: Int) -> String {
        supportedLanguageNames.indices.contains(compactID) ? supportedLanguageNames[compactID] : "Language \(compactID)"
    }
    private var originalParameters: MiniEXUserParameters?
    private var pendingParameterPayload: Data?
    private var pendingParameterModeChanged = false
    private var parameterWriteRetries = 0
    private lazy var downloader: DataDownload = {
        let value = DataDownload()
        value.send = { [weak self] pid, id, payload in self?.sendCM(id, payload: payload, target: pid, source: 4, flags: 0) }
        value.onUpdate = { [weak self] records, status in self?.records = records; self?.status = status }
        return value
    }()
    private var nextPacketID: UInt16 = 0
    private var deviceKeyHeld = false
    private var connectedEndpoint = "—"
    private let transport: MiniEXTransport = TCPTransport(); private let decoder = PacketStreamDecoder()
    private let log = DiagnosticLog()
    private var display: RCDisplay?
    private var replayTask: Task<Void, Never>?
    private var refreshScheduled = false
    private var receivedRCFrames = 0
    private var successfulWrites = 0
    var diagnosticFileURL: URL { log.url }
    init() {
        do { display = RCDisplay(resources: try RCResources.load(language: rcLanguage)); displayImage = display?.image() }
        catch { appendDiagnostic("RC RESOURCES ERROR: \(error)") }
        appendDiagnostic("App launched, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))")
        transport.onRawData = { [log] data in log.rawTCP(data) }
        transport.onState = { [weak self] value in Task { @MainActor in
            guard let self else { return }
            if self.isOfflineDemo { return }
            self.connectionState = value; self.isConnected = value == "Connected"
            self.appendDiagnostic("SOCKET: \(value)")
            if value == "Connected" {
                self.detectingDevice = true
                self.status = "Detecting device…"
                self.sendCM(WireMessage.getFirmware, target: 7, source: 3, flags: 0)
                let generation = self.detectionGeneration
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard let self, self.isConnected, self.detectingDevice, self.detectionGeneration == generation else { return }
                    self.status = "Device identification timed out."
                    self.appendDiagnostic("DETECTION: still waiting for firmware reply after four seconds")
                }
            } else {
                self.detectionGeneration &+= 1
                self.detectingDevice = false
                self.settingsReadRequested = false
                self.deviceSupportsRemote = false
                self.remoteActive = false
                self.display?.clear(); self.displayImage = self.display?.image()
                self.downloader.cancel()
                self.status = self.connectionState
                if self.deviceKeyHeld { self.deviceKeyHeld = false; self.appendDiagnostic("RC KEY: connection ended while button held") }
            }
        } }
        transport.onWrite = { [weak self] count, error in Task { @MainActor in
            guard let self else { return }
            if let error { self.appendDiagnostic("TX ERROR: \(count) B: \(error)"); self.status = error }
            else {
                self.bytesSent += count
                self.successfulWrites += 1
                if self.successfulWrites == 1 || self.successfulWrites.isMultiple(of: 20) {
                    self.appendDiagnostic("TX COMPLETE: \(self.successfulWrites) writes, \(self.bytesSent) B handed to TCP stack")
                }
            }
        } }
        transport.onData = { [weak self] data in Task { @MainActor in
            guard let self, !self.isOfflineDemo else { return }
            self.bytesReceived += data.count
            self.appendDiagnostic("RX TCP: \(data.count) B")
            // Every raw byte is already persisted before this callback by onRawData.
            self.consume(data)
        } }
    }
    func connect(bridge: Bool = false) {
        cancelReplay()
        isOfflineDemo = false
        let selectedHost = bridge ? bridgeHost : host; let selectedPort = UInt16(clamping: bridge ? bridgePort : port)
        guard !selectedHost.isEmpty, selectedPort > 0 else { appendDiagnostic("CONNECT ERROR: invalid host or port"); return }
        releaseDeviceKey()
        decoder.reset()
        remoteActive = false
        detectingDevice = false; detectionGeneration &+= 1; deviceSupportsRemote = false
        settingsReadRequested = false
        originalParameters = nil; firmwareVersion = nil
        receivedRCFrames = 0
        do { display = RCDisplay(resources: try RCResources.load(language: rcLanguage)); displayImage = display?.image() }
        catch { appendDiagnostic("RC RESOURCES ERROR: \(error.localizedDescription)") }
        connectedEndpoint = "\(selectedHost):\(selectedPort)"
        appendDiagnostic("CONNECT: \(selectedHost):\(selectedPort) mode=\(bridge ? "bridge" : "Wi-Fi")")
        transport.connect(host: selectedHost, port: selectedPort)
    }
    func connectViaWiFi(completion: @escaping (Bool) -> Void = { _ in }) {
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            let matches = network?.ssid.localizedCaseInsensitiveContains("miniEXPLONIX") == true
            Task { @MainActor in
                guard let self else { return }
                if matches { self.connect(); completion(true) }
                else { self.status = "Join a Wi-Fi network whose SSID contains miniEXPLONIX first."; self.appendDiagnostic("WIFI CHECK: current SSID is not a miniEXPLONIX access point"); completion(false) }
            }
        }
    }
    func disconnect() { releaseDeviceKey(); appendDiagnostic("DISCONNECT: user request"); transport.disconnect() }
    var activeEndpoint: String { connectedEndpoint }
    func sendCM(_ id: UInt16, payload: Data = Data(), target: UInt8, source: UInt8 = 5, flags: UInt8 = 0x20) {
        guard isConnected else { appendDiagnostic("TX SKIPPED: socket is not ready, CM=0x\(String(format: "%04X", id))"); return }
        let cm = CMCodec.encode(target: target, source: source, flags: flags, id: id, payload: payload)
        let packetID = nextPacketID
        nextPacketID &+= 1
        let packet = PacketCodec.build(id: packetID, payload: cm)
        bytesQueued += packet.count
        if id == WireMessage.stream && payload.count == 2 && flags == 0x20 {
            log.write("TX RC ACK packet=\(packetID) seq=\(UInt16(payload[0]) | UInt16(payload[1]) << 8) ASCII=\(String(decoding: packet, as: UTF8.self))")
        } else {
            appendDiagnostic("TX PACKET: #002 id=0x\(String(format: "%04X", packetID)) len=\(cm.count) B checksum=\(String(decoding: packet.suffix(4), as: UTF8.self))")
            appendDiagnostic("TX CM: target=0x\(String(format: "%02X", target)) source=0x\(String(format: "%02X", source)) flags=0x\(String(format: "%02X", flags)) id=0x\(String(format: "%04X", id)) data=\(payload.count) B")
            appendDiagnostic("TX ASCII: \(String(decoding: packet, as: UTF8.self))")
            appendDiagnostic("TX HEX: \(packet.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        transport.send(packet)
    }
    func startRemote() {
        guard isConnected, deviceSupportsRemote else { return }
        // Android MiniExProtocol.remoteOn(): retries=0, timeout=500 ms, little endian.
        sendCM(WireMessage.streamOn, payload: Data([0, 0, 0xf4, 0x01]), target: 1, flags: 0)
        sendCM(WireMessage.redraw, target: 2)
        remoteActive = true
        appendDiagnostic("RC ON: activation requested")
    }
    func stopRemote() {
        guard isConnected else { return }
        releaseDeviceKey()
        sendCM(WireMessage.streamOff, target: 1, flags: 0)
        remoteActive = false
        display?.clear(); displayImage = display?.image()
        appendDiagnostic("RC OFF: deactivation requested")
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
        guard isConnected else { return }
        settingsReadRequested = true
        originalParameters = nil
        if !detectingDevice {
            if let version = firmwareVersion { requestSettings(for: version) }
            else { sendCM(WireMessage.getFirmware, target: 7, source: 3, flags: 0) }
        }
        status = "Reading device settings…"
    }
    private func requestSettings(for version: MiniEXFirmwareVersion) {
        sendCM(WireMessage.getSerial, target: 7, source: 3, flags: 0)
        if version.firmwareCode >= 0x0111 { sendCM(WireMessage.getLanguages, target: 7, source: 3, flags: 0) }
        else {
            supportedLanguages = version.firmwareCode >= 0x010c ? [0, 1, 2] : [0, 1]
            supportedLanguageNames = version.firmwareCode >= 0x010c ? ["Default (English)", "English", "Japanese"] : ["Default (English)", "English"]
            sendCM(WireMessage.getBounds, target: 5, source: 3, flags: 0)
        }
    }
    func saveSettings() {
        guard let version = firmwareVersion, let original = originalParameters else {
            status = "Read settings from the device before saving."; return
        }
        do {
            let wireValues = parameters.wireValues(bounds: parameterBounds, original: original)
            for index in MiniEXUserParametersCodec.editableParameterIndices {
                guard (parameterBounds.rawMinimum(index)...parameterBounds.rawMaximum(index)).contains(wireValues.raw[index]) else {
                    throw CodecError.malformed("Parameter \(index) is outside device limits")
                }
            }
            for (zero, alarm) in [(0, 1), (8, 9), (10, 11)] where zero == 0 || (zero == 8 ? version.availableModes > 1 : version.availableModes > 2) {
                guard wireValues.raw[zero] < wireValues.raw[alarm] * 10 else { throw CodecError.malformed("Zero threshold must be below ten times the alarm threshold") }
            }
            guard supportedLanguages.contains(parameters.primaryLanguage), supportedLanguages.contains(parameters.secondaryLanguage) else {
                throw CodecError.malformed("Unsupported device language")
            }
            let payload = try MiniEXUserParametersCodec.encodeValues(wireValues, dataTypeSize: version.dataTypeSize)
            pendingParameterPayload = payload
            pendingParameterModeChanged = wireValues.modeIndex != original.modeIndex
            parameterWriteRetries = 0
            sendPendingParameterWrite()
            status = "Settings sent; waiting for device confirmation."
        } catch { status = error.localizedDescription }
    }
    private func sendPendingParameterWrite() {
        guard let payload = pendingParameterPayload else { return }
        sendCM(WireMessage.setParameters, payload: payload, target: 5, source: 3, flags: 0)
    }
    func restoreDefaults() { sendCM(WireMessage.defaults, target: 5, source: 3, flags: 0); status = "Restore defaults requested." }
    func refreshData(maxCount: Int = 0) {
        guard isConnected else { status = "Connect to download records."; return }
        downloader.start(maxCount); status = maxCount > 0 ? "Reading up to \(maxCount) records…" : "Reading device storage…"
    }
    func eraseData() { guard isConnected else { return }; downloader.erase(); status = "Erase requested." }
    func changeRCLanguage() {
        do {
            display = RCDisplay(resources: try RCResources.load(language: rcLanguage))
            displayImage = display?.image()
            if isConnected && remoteActive { sendCM(WireMessage.redraw, target: 2) }
        } catch { status = error.localizedDescription }
    }
    func demo() {
        cancelReplay()
        if isConnected { disconnect() }
        isOfflineDemo = true
        isConnected = false; connectionState = "Offline demo"; status = "Sample data without device"
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
    func playOffline(_ recording: OfflineRecording) {
        demo()
        do {
            let frames = try OfflineReplay.load(recording)
            let resources = try RCResources.load(language: rcLanguage)
            display = RCDisplay(resources: resources)
            displayImage = display?.image()
            replayTotal = frames.count
            replayProgress = 0
            replayPlaying = true
            status = "Playing \(recording.title)"
            appendDiagnostic("OFFLINE START: \(recording.rawValue), \(frames.count) RC frames")
            replayTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for (index, frame) in frames.enumerated() {
                    if Task.isCancelled { break }
                    self.display?.apply(frame.commands)
                    if index.isMultiple(of: 4) || index == frames.count - 1 {
                        self.displayImage = self.display?.image()
                        self.replayProgress = index + 1
                    }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
                if !Task.isCancelled {
                    self.replayPlaying = false
                    self.status = "Recording processed: \(self.replayProgress) / \(self.replayTotal) frames"
                    self.appendDiagnostic("OFFLINE END: \(self.replayProgress) / \(self.replayTotal)")
                }
            }
        } catch {
            status = "Offline replay failed: \(error.localizedDescription)"
            appendDiagnostic("OFFLINE ERROR: \(error.localizedDescription)")
        }
    }
    func cancelReplay() {
        if replayPlaying { status = "Replay stopped at frame \(replayProgress)." }
        replayTask?.cancel()
        replayTask = nil
        replayPlaying = false
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
    func clearDiagnostics() { diagnosticLines.removeAll(); bytesSent = 0; bytesQueued = 0; bytesReceived = 0; packetCount = 0; cmMessageCount = 0; appendDiagnostic("Diagnostics cleared") }
    var diagnosticText: String { diagnosticLines.joined(separator: "\n") }
    private func consume(_ data: Data) {
        do {
            for packet in try decoder.append(data) {
                packetCount += 1
                let messages = try CMCodec.decodeAll(packet.payload)
                let containsRC = messages.contains { $0.targetPID == 5 && $0.sourcePID == 1 && $0.messageID == WireMessage.stream }
                if !containsRC {
                    appendDiagnostic("RX PACKET: type=\(packet.type) to=\(packet.receiver) from=\(packet.sender) id=0x\(String(format: "%04X", packet.id)) data=\(packet.payload.count) B")
                    appendDiagnostic("RX ASCII: \(String(decoding: packet.payload, as: UTF8.self))")
                }
                for message in messages {
                    cmMessageCount += 1
                    if !containsRC { appendDiagnostic("RX CM: id=0x\(String(format: "%04X", message.messageID)) source=\(message.sourcePID) flags=0x\(String(format: "%02X", message.flags)) data=\(message.payload.count) B") }
                    if message.targetPID == 5, message.sourcePID == 1, message.messageID == WireMessage.stream, message.payload.count >= 2 {
                        let sequence = Data(message.payload.prefix(2))
                        let sequenceNumber = UInt16(sequence[0]) | UInt16(sequence[1]) << 8
                        sendCM(WireMessage.stream, payload: sequence, target: 1)
                        do {
                            let (_, commands) = try RCStream.decode(message.payload)
                            log.write("RC FRAME BEGIN seq=\(sequenceNumber) commands=\(commands.map { String(format: "%02X", $0.id) }.joined(separator: ","))", flush: true)
                            if remoteActive {
                                display?.apply(commands)
                                scheduleDisplayRefresh()
                            }
                            receivedRCFrames += 1
                            log.write("RC FRAME END seq=\(sequenceNumber)")
                            if receivedRCFrames == 1 || receivedRCFrames.isMultiple(of: 20) {
                                appendDiagnostic("RX RC: \(receivedRCFrames) frames, seq=\(sequenceNumber), commands=\(commands.count), ACK")
                            }
                        } catch { appendDiagnostic("RC DECODE ERROR: \(error.localizedDescription)") }
                    }
                    if message.targetPID == 5, message.sourcePID == 1, message.messageID == WireMessage.streamOff, message.flags & 0x40 != 0 {
                        appendDiagnostic("RC OFF ANSWER: \(message.flags & 0x80 == 0 ? "OK" : "ERROR")")
                    }
                    downloader.receive(message)
                    if message.targetPID == 3 { handle(message) }
                }
            }
        } catch { status = error.localizedDescription; appendDiagnostic("DECODE ERROR: \(error.localizedDescription)") }
    }
    private func scheduleDisplayRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let self else { return }
            self.refreshScheduled = false
            if !self.isOfflineDemo && self.remoteActive { self.displayImage = self.display?.image() }
        }
    }
    private func appendDiagnostic(_ text: String) {
        let important = text.hasPrefix("SOCKET:") || text.hasPrefix("CONNECT:") || text.contains("ERROR:")
        log.write(text, flush: important)
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
        diagnosticLines.append("[\(formatter.string(from: Date()))] \(text)")
        if diagnosticLines.count > 500 { diagnosticLines.removeFirst(diagnosticLines.count - 500) }
    }
    private func handle(_ m: CMMessage) {
        switch m.messageID {
        case WireMessage.getFirmware where m.sourcePID == 7 && m.flags & 0x40 != 0:
            firmwareVersion = try? MiniEXFirmwareVersion.decode(m.payload)
            if let version = firmwareVersion {
                firmware = "\(version.modelName), FW \(version.displayName)"
                let wasDetecting = detectingDevice
                detectingDevice = false
                deviceSupportsRemote = version.supportsRemoteControl
                if wasDetecting {
                    appendDiagnostic("DETECTED: \(firmware), RC supported=\(deviceSupportsRemote)")
                    if deviceSupportsRemote { startRemote() }
                    else { status = "Connected device does not support Remote Control." }
                }
                if settingsReadRequested { requestSettings(for: version) }
            }
        case WireMessage.getSerial where m.payload.count >= 4:
            var serialValue: UInt32 = 0
            for byteIndex in 0..<4 {
                serialValue |= UInt32(m.payload[byteIndex]) << UInt32(byteIndex * 8)
            }
            serial = String(serialValue)
        case WireMessage.getLanguages where m.payload.count == 2:
            let mask = MiniEXUserParametersCodec.readU16(m.payload, at: 0)
            let languages = ["English", "Japanese", "Arabic", "Traditional Chinese", "Simplified Chinese", "German", "Polish"]
            let supported = (1...7).filter { mask & (1 << ($0 - 1)) != 0 }
            supportedLanguages = Array(0...supported.count)
            supportedLanguageNames = ["Default (English)"] + supported.map { languages[$0 - 1] }
            sendCM(WireMessage.getBounds, target: 5, source: 3, flags: 0)
        case WireMessage.getBounds:
            do { parameterBounds = try MiniEXUserParametersCodec.decodeBounds(m.payload); sendCM(WireMessage.getParameters, target: 5, source: 3, flags: 0); status = "Device limits read." }
            catch { status = error.localizedDescription }
        case WireMessage.getParameters:
            do {
                let size = firmwareVersion?.dataTypeSize ?? 3
                let values = try MiniEXUserParametersCodec.decodeValues(m.payload, dataTypeSize: size).normalized(to: parameterBounds)
                originalParameters = values
                parameters = DeviceParameters(wireValues: values, bounds: parameterBounds)
                settingsReadRequested = false
                status = "Device settings read."
            } catch { status = error.localizedDescription }
        case WireMessage.setParametersBusy:
            guard pendingParameterPayload != nil else { break }
            if parameterWriteRetries < 3 {
                parameterWriteRetries += 1
                status = "Device busy; retrying parameter write (\(parameterWriteRetries)/3)…"
                appendDiagnostic("PARAMETERS: device busy, retry \(parameterWriteRetries)")
                sendPendingParameterWrite()
            } else {
                pendingParameterPayload = nil
                status = "Device remained busy; parameters were not saved."
                appendDiagnostic("PARAMETERS ERROR: device remained busy after 3 retries")
            }
        case WireMessage.setParameters:
            guard pendingParameterPayload != nil, m.flags & 0x40 != 0 else { break }
            guard m.flags & 0x80 == 0, m.payload.count == 1, m.payload.first == 0 else {
                pendingParameterPayload = nil
                status = "Device rejected settings."
                appendDiagnostic("PARAMETERS ERROR: invalid write acknowledgement flags=0x\(String(format: "%02X", m.flags)) payload=\(m.payload.count) B")
                break
            }
            let modeChanged = pendingParameterModeChanged
            pendingParameterPayload = nil
            parameterWriteRetries = 0
            if modeChanged {
                sendCM(WireMessage.systemOff, target: 2, source: 5, flags: 0x20)
                status = "Parameters saved; device power-off requested for mode change."
            } else {
                status = "Parameters saved. Reading them back…"
                refreshSettings()
            }
        case WireMessage.stream, WireMessage.streamOff: break
        default: status = "Received message 0x\(String(m.messageID, radix: 16))"
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
    func wireValues(bounds: MiniEXParameterBounds, original: MiniEXUserParameters = .defaults) -> MiniEXUserParameters {
        var raw = original.raw
        let displays = [wideZero, wideAlarm, offTime, sampling, beep, alarm]
        for index in displays.indices { raw[index] = MiniEXUserParametersCodec.displayToRaw(parameter: index, display: displays[index], scale: bounds.rawScale(index)) }
        raw[7] = Int(irPower)
        raw[8] = MiniEXUserParametersCodec.displayToRaw(parameter: 8, display: advancedZero, scale: bounds.rawScale(8))
        raw[9] = MiniEXUserParametersCodec.displayToRaw(parameter: 9, display: advancedAlarm, scale: bounds.rawScale(9))
        raw[10] = MiniEXUserParametersCodec.displayToRaw(parameter: 10, display: tatpZero, scale: bounds.rawScale(10))
        raw[11] = MiniEXUserParametersCodec.displayToRaw(parameter: 11, display: tatpAlarm, scale: bounds.rawScale(11))
        var flags = wifi ? original.raw[6] | MiniEXUserParametersCodec.wifiMask : original.raw[6] & ~MiniEXUserParametersCodec.wifiMask
        flags = MiniEXUserParametersCodec.withLanguageID(bitConfig: flags, primary: true, languageID: primaryLanguage)
        flags = MiniEXUserParametersCodec.withLanguageID(bitConfig: flags, primary: false, languageID: secondaryLanguage)
        flags = (flags & ~MiniEXUserParametersCodec.modeMask) | ((mode << MiniEXUserParametersCodec.modeShift) & MiniEXUserParametersCodec.modeMask)
        raw[MiniEXUserParametersCodec.bitConfigIndex] = flags
        return MiniEXUserParameters(raw: raw, valid: original.valid)
    }
}
