import XCTest
@testable import miniEXView

final class ProtocolTests: XCTestCase {
    func testAlphaHex() throws { XCTAssertEqual(AlphaHex.encode(Data([0,0x1f,0xa5,0xff])),"AA BP KF PP".replacingOccurrences(of:" ",with:"")); XCTAssertEqual(try AlphaHex.decode("BEEF"[...]),0x1445) }
    func testPacketRoundTrip() throws { let built=PacketCodec.build(receiver:"a",sender:"b",id:0x1234,payload:Data("hello".utf8)); let decoded=try PacketStreamDecoder().append(built); XCTAssertEqual(decoded.first?.id,0x1234); XCTAssertEqual(decoded.first?.payload,Data("hello".utf8)) }
    func testCMRoundTrip() throws { let data=CMCodec.encode(target:5,source:3,id:0x0241,payload:Data([1,2])); let decoded=try CMCodec.decodeAll(data); XCTAssertEqual(decoded.first?.messageID,0x0241); XCTAssertEqual(decoded.first?.payload,Data([1,2])) }
    func testFirmwareLayout() {
        let version = MiniEXFirmwareVersion.from(word: UInt16((3 << 13) | 0x0212))
        XCTAssertEqual(version.displayName, "2.18")
        XCTAssertEqual(version.dataTypeSize, 3)
        XCTAssertEqual(version.availableModes, 3)
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
