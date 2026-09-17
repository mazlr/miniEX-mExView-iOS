import Foundation

struct StorageConfig {
    let start: UInt32, end: UInt32
    let sectors: Int, sectorSize: Int, recordShift: Int, recordSize: Int, flagOffset: Int
    init(_ d: Data) throws {
        guard d.count == 20 else { throw CodecError.malformed("Invalid storage configuration length") }
        start = Self.u32(d, 0); end = Self.u32(d, 4)
        sectors = Self.u16(d, 8); sectorSize = Self.u16(d, 10)
        recordShift = Self.u16(d, 12); recordSize = Self.u16(d, 14); flagOffset = Self.u16(d, 18)
        guard recordSize == 16, recordShift < 16, flagOffset < recordSize, sectors > 0 else {
            throw CodecError.malformed("Unsupported storage layout")
        }
    }
    var capacity: Int { (sectors - 1) * (sectorSize >> recordShift) }
    static func u16(_ d: Data, _ i: Int) -> Int { Int(d[i]) | Int(d[i+1]) << 8 }
    static func u32(_ d: Data, _ i: Int) -> UInt32 { UInt32(u16(d, i)) | UInt32(u16(d, i+2)) << 16 }
}

enum StoredRecordCodec {
    static func decode(_ d: Data, index: Int) throws -> MeasuredRecord {
        guard d.count == 16 else { throw CodecError.malformed("Record must contain 16 bytes") }
        let packed = StorageConfig.u32(d, 0)
        var parts = DateComponents()
        parts.year = 2000 + Int((packed >> 26) & 63)
        parts.month = Int((packed >> 22) & 15); parts.day = Int((packed >> 17) & 31)
        parts.hour = Int((packed >> 12) & 31); parts.minute = Int((packed >> 6) & 63)
        parts.second = Int(packed & 63)
        let flags = d[14]
        return MeasuredRecord(index: index + 1, timestamp: Calendar.current.date(from: parts) ?? Date(timeIntervalSince1970: 0),
                              value: flags & 1 != 0 ? 0 : Double(StorageConfig.u32(d, 4)),
                              alarm: flags & 2 != 0, mode: Int((flags >> 4) & 3),
                              period: StorageConfig.u16(d, 8))
    }
}

@MainActor final class DataDownload {
    enum Stage { case idle, rtc, firmware, config, status, lastRecord, records, erase }
    private(set) var stage: Stage = .idle
    private var config: StorageConfig?
    private var freeAddress: UInt32 = 0
    private var nextIndex = 0
    private var total = 0
    private var requestedCount = 0
    private var retry = 0
    private var lastCommand: (UInt8, UInt16, Data)?
    private(set) var collected: [MeasuredRecord] = []
    var send: ((UInt8, UInt16, Data) -> Void)?
    var onUpdate: (([MeasuredRecord], String) -> Void)?
    var isBusy: Bool { stage != .idle }
    func cancel() { stage = .idle; lastCommand = nil }
    func start(_ maxCount: Int = 0) {
        guard !isBusy else { return }
        requestedCount = max(0, maxCount)
        collected = []; config = nil; stage = .rtc
        request(4, 0x0401, Data([0, 7]))
    }
    func erase() {
        guard !isBusy else { return }
        stage = .erase; request(8, 0x0D02, Data([0, 0]))
    }
    private func request(_ pid: UInt8, _ id: UInt16, _ payload: Data) {
        retry = 0; lastCommand = (pid, id, payload); send?(pid, id, payload)
    }
    private func fail(_ reason: String) { cancel(); onUpdate?(collected, reason) }
    func receive(_ m: CMMessage) {
        guard m.targetPID == 4, let command = lastCommand, command.0 == m.sourcePID,
              m.messageID & 0xff7f == command.1 else { return }
        if m.flags & 0x80 != 0 || m.messageID & 0x80 != 0 { retryOrFail("Storage command rejected"); return }
        do { try process(m.payload) }
        catch { retryOrFail(error.localizedDescription) }
    }
    private func retryOrFail(_ detail: String) {
        guard let command = lastCommand else { return }
        retry += 1
        if retry <= 5 { send?(command.0, command.1, command.2) }
        else { fail("Download failed: \(detail)") }
    }
    private func process(_ d: Data) throws {
        switch stage {
        case .rtc:
            guard d.count == 7 else { throw CodecError.malformed("Invalid RTC reply") }
            stage = .firmware; request(7, 0x0B06, Data())
        case .firmware:
            guard d.count == 2 else { throw CodecError.malformed("Invalid firmware reply") }
            stage = .config; request(8, 0x0D05, Data([0, 0]))
        case .config:
            config = try StorageConfig(d); stage = .status; request(8, 0x0D06, Data([0, 0]))
        case .status:
            guard d.count == 11, let config else { throw CodecError.malformed("Invalid storage status") }
            freeAddress = StorageConfig.u32(d, 0)
            let address = config.end &+ 1 &- UInt32(config.recordSize)
            stage = .lastRecord
            request(5, 0x0502, Data([UInt8(truncatingIfNeeded: address), UInt8(truncatingIfNeeded: address >> 8), UInt8(truncatingIfNeeded: address >> 16), UInt8(truncatingIfNeeded: address >> 24), 16, 0]))
        case .lastRecord:
            guard let config, d.count == 4 + config.recordSize,
                  StorageConfig.u32(d, 0) == config.end &+ 1 &- UInt32(config.recordSize) else { throw CodecError.malformed("Invalid final flash record") }
            total = d[4 + config.flagOffset] != 0xff ? config.capacity : Int((freeAddress &- config.start) / UInt32(config.recordSize))
            total = min(max(total, 0), config.capacity)
            if requestedCount > 0 { total = min(total, requestedCount) }
            nextIndex = 0
            if total == 0 { cancel(); onUpdate?([], "No records on device") }
            else { stage = .records; requestRecord() }
        case .records:
            collected.append(try StoredRecordCodec.decode(d, index: nextIndex))
            nextIndex += 1
            onUpdate?(collected, "Downloading records \(nextIndex)/\(total)")
            if nextIndex >= total { cancel(); onUpdate?(collected, "Downloaded \(total) records") }
            else { requestRecord() }
        case .erase:
            cancel(); collected = []; onUpdate?([], "Device records erased")
        case .idle: break
        }
    }
    private func requestRecord() {
        request(8, 0x0D03, Data([0, 0, UInt8(truncatingIfNeeded: nextIndex), UInt8(truncatingIfNeeded: nextIndex >> 8)]))
    }
}
