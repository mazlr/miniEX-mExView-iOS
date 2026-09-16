import XCTest
@testable import miniEXView

final class ProtocolTests: XCTestCase {
    func testLocalizedCatalogsAndStorageDecode() throws {
        for language in ["English", "Japanese", "Arabic", "TraditionalChinese", "SimplifiedChinese", "German", "Polish"] {
            let catalog = try RCResources.load(language: language)
            XCTAssertEqual(catalog.bitmaps.count, 43, language)
            XCTAssertNotNil(RCDisplay(resources: catalog).image())
        }
        var stored = Data(repeating: 0, count: 16)
        var packed: UInt32 = 24 << 26
        packed |= 9 << 22
        packed |= 16 << 17
        packed |= 13 << 12
        packed |= 42 << 6
        packed |= 5
        for i in 0..<4 { stored[i] = UInt8(truncatingIfNeeded: packed >> (8*i)) }
        stored[4] = 37; stored[8] = 80; stored[14] = 0x12
        let record = try StoredRecordCodec.decode(stored, index: 0)
        XCTAssertEqual(record.value, 37)
        XCTAssertEqual(record.period, 80)
        XCTAssertEqual(record.mode, 1)
        XCTAssertTrue(record.alarm)
    }
    @MainActor func testDownloaderUsesStorageCommandsAndReadsRecord() throws {
        let downloader = DataDownload()
        var sent: [(UInt8, UInt16, Data)] = []
        downloader.send = { sent.append(($0, $1, $2)) }
        downloader.start()
        XCTAssertEqual(sent.last?.1, 0x0401)
        func reply(_ pid: UInt8, _ id: UInt16, _ payload: Data) {
            downloader.receive(CMMessage(targetPID: 4, sourcePID: pid, flags: 0x40, messageID: id, payload: payload))
        }
        reply(4, 0x0401, Data(repeating: 0, count: 7))
        reply(7, 0x0B06, Data([0x12, 0x02]))
        var config = Data(repeating: 0, count: 20)
        config[4] = 0x3f; config[8] = 2; config[10] = 16; config[12] = 4; config[14] = 16; config[18] = 14
        reply(8, 0x0D05, config)
        var status = Data(repeating: 0, count: 11)
        status[0] = 16
        reply(8, 0x0D06, status)
        XCTAssertEqual(sent.last?.1, 0x0502)
        XCTAssertEqual(sent.last?.2.count, 6)
        var final = Data(repeating: 0, count: 20)
        final[0] = 0x30; final[18] = 0xff
        reply(5, 0x0502, final)
        XCTAssertEqual(sent.last?.1, 0x0D03)
        XCTAssertEqual(sent.last?.2, Data([0, 0, 0, 0]))
        reply(8, 0x0D03, Data(repeating: 0, count: 16))
        XCTAssertEqual(downloader.collected.count, 1)
        XCTAssertFalse(downloader.isBusy)
    }
    func testCapturedLogsAndRemoteRenderer() throws {
        let resource = try RCResources.load()
        XCTAssertEqual(resource.bitmaps.count, 43)
        XCTAssertEqual(resource.fonts.count, 3)
        XCTAssertEqual(resource.bargraphs.count, 26)
        let display = RCDisplay(resources: resource)
        var totalRC = 0
        for file in ["RC from miniEX long", "RC from miniEX short", "RC to miniEX long", "RC to miniEX short", "SetParam from miniEX", "SetParam to miniEX"] {
            let folder = try XCTUnwrap(Bundle(for: ProtocolTests.self).url(forResource: file, withExtension: "txt", subdirectory: "Fixtures"))
            let text = try String(contentsOf: folder, encoding: .utf8)
            var packets = 0
            for line in text.split(whereSeparator: \.isNewline) {
                let bytes = Data(String(line).trimmingCharacters(in: CharacterSet(charactersIn: "~")).utf8)
                let decoded = try PacketStreamDecoder().append(bytes)
                XCTAssertEqual(decoded.count, 1, "\(file): \(packets)")
                for packet in decoded {
                    packets += 1
                    for message in try CMCodec.decodeAll(packet.payload) where message.targetPID == 5 && message.sourcePID == 1 && message.messageID == WireMessage.stream {
                        let (_, commands) = try RCStream.decode(message.payload)
                        display.apply(commands)
                        XCTAssertNotNil(display.image(), "Vykreslení selhalo po RC rámci \(totalRC + 1) souboru \(file)")
                        totalRC += 1
                    }
                }
            }
            XCTAssertGreaterThan(packets, 0)
        }
        XCTAssertEqual(totalRC, 760)
        XCTAssertNotNil(display.image())
    }
    func testBundledOfflineReplayUsesCapturedFrames() throws {
        let expected: [(OfflineRecording, Int)] = [(.short, 65), (.long, 695)]
        for (recording, count) in expected {
            let frames = try OfflineReplay.load(recording)
            XCTAssertEqual(frames.count, count)
            let display = RCDisplay(resources: try RCResources.load())
            for frame in frames { display.apply(frame.commands) }
            XCTAssertNotNil(display.image())
        }
    }
    func testAlphaHex() throws {
        let encoded = AlphaHex.encode(Data([0, 0x1f, 0xa5, 0xff]))
        XCTAssertEqual(encoded, "AABPKFPP")
        let decoded: Int = try AlphaHex.decode("BEEF"[...])
        XCTAssertEqual(decoded, 0x1445)
    }
    func testPacketRoundTrip() throws {
        let built = PacketCodec.build(receiver: "a", sender: "b", id: 0x1234, payload: Data("hello".utf8))
        let decoded = try PacketStreamDecoder().append(built)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, 0x1234)
        XCTAssertEqual(decoded[0].payload, Data("hello".utf8))
    }
    func testPacketStreamAcrossPacketsAndFragments() throws {
        let decoder = PacketStreamDecoder()
        let first = PacketCodec.build(id: 1, payload: Data("first".utf8))
        let second = PacketCodec.build(id: 2, payload: Data("second".utf8))
        XCTAssertEqual(try decoder.append(first).map(\.id), [1])
        XCTAssertTrue(try decoder.append(second.prefix(7)).isEmpty)
        XCTAssertEqual(try decoder.append(second.dropFirst(7)).map(\.id), [2])
        XCTAssertEqual(try decoder.append(first + second).map(\.id), [1, 2])
    }
    func testCMRoundTrip() throws {
        let data = CMCodec.encode(target: 5, source: 3, id: 0x0241, payload: Data([1, 2]))
        let decoded = try CMCodec.decodeAll(data)
        XCTAssertEqual(decoded.first?.messageID, 0x0241)
        XCTAssertEqual(decoded.first?.targetPID, 5)
        XCTAssertEqual(decoded.first?.sourcePID, 3)
        XCTAssertEqual(decoded.first?.payload, Data([1, 2]))
    }
    func testAndroidCapturedKeyPressPacket() throws {
        let cm = CMCodec.encode(target: 6, source: 5, flags: 0x20, id: WireMessage.keyPress)
        let packet = PacketCodec.build(type: "0", receiver: "0", sender: "2", id: 0x00ab, payload: cm)
        XCTAssertEqual(String(decoding: packet, as: UTF8.self), "#002 AAKL AO *aAAAGAFCAABADAGED")
        let decoded = try PacketStreamDecoder().append(packet)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].id, 0x00ab)
        let message = try XCTUnwrap(CMCodec.decodeAll(decoded[0].payload).first)
        XCTAssertEqual(message.targetPID, 6)
        XCTAssertEqual(message.sourcePID, 5)
        XCTAssertEqual(message.flags, 0x20)
        XCTAssertEqual(message.messageID, WireMessage.keyPress)
    }
    func testRemoteOnPayloadMatchesAndroid() throws {
        let cm = CMCodec.encode(target: 1, source: 5, flags: 0, id: WireMessage.streamOn, payload: Data([0, 0, 0xf4, 1]))
        let message = try XCTUnwrap(CMCodec.decodeAll(cm).first)
        XCTAssertEqual(message.payload, Data([0, 0, 0xf4, 1]))
        XCTAssertEqual(message.targetPID, 1)
        XCTAssertEqual(String(decoding: PacketCodec.build(type: "0", receiver: "0", sender: "2", id: 0x10ab, payload: cm), as: UTF8.self),
                       "#002 BAKL BG *aAEABAFAAEBACAAAAPEABAIFJ")
        let redraw = CMCodec.encode(target: 2, source: 5, flags: 0x20, id: WireMessage.redraw)
        XCTAssertEqual(String(decoding: PacketCodec.build(type: "0", receiver: "0", sender: "2", id: 0x10ac, payload: redraw), as: UTF8.self),
                       "#002 BAKM AO *aAAACAFCABAAGAGEE")
    }
    func testFirmwareLayout() {
        let version = MiniEXFirmwareVersion.from(word: UInt16((3 << 13) | 0x0212))
        XCTAssertEqual(version.displayName, "2.18")
        XCTAssertEqual(version.dataTypeSize, 3)
        XCTAssertEqual(version.availableModes, 3)
        XCTAssertTrue(version.supportsRemoteControl)
        XCTAssertFalse(MiniEXFirmwareVersion.from(word: 0).supportsRemoteControl)
    }
    func testUserParameterRoundTripWithSignedHeatFlow() throws {
        let raw = [1234,321,600*16,15*16,4,5,0x0193,-50,2345,456,3456,567,0]
        let encoded = try MiniEXUserParametersCodec.encodeValues(.init(raw: raw, valid: 0), dataTypeSize: 3)
        let decoded = try MiniEXUserParametersCodec.decodeValues(encoded, dataTypeSize: 3)
        XCTAssertEqual(encoded.count, 28)
        XCTAssertEqual(decoded.valid, 1)
        XCTAssertEqual(decoded.raw, raw)
    }
    func testLegacyParametersAndScaling() throws {
        let source = MiniEXUserParameters(raw: [1000,200,9600,240,5,4,0x12,-50,777,888,999,111,222])
        let encoded = try MiniEXUserParametersCodec.encodeValues(source, dataTypeSize: 1)
        let decoded = try MiniEXUserParametersCodec.decodeValues(encoded, dataTypeSize: 1)
        XCTAssertEqual(encoded.count, 18)
        XCTAssertEqual(decoded.raw[7], -50)
        XCTAssertEqual(decoded.raw[8], 0)
        XCTAssertEqual(MiniEXUserParametersCodec.displayToRaw(parameter: 2, display: 15.9, scale: 16), 240)
        XCTAssertEqual(MiniEXUserParametersCodec.rawToDisplay(parameter: 2, raw: 240, scale: 16), 15)
    }
}
