import XCTest
@testable import miniEXView

final class ProtocolTests: XCTestCase {
    func testAlphaHex() throws { XCTAssertEqual(AlphaHex.encode(Data([0,0x1f,0xa5,0xff])),"AA BP KF PP".replacingOccurrences(of:" ",with:"")); XCTAssertEqual(try AlphaHex.decode("BEEF"[...]),0x1445) }
    func testPacketRoundTrip() throws { let built=PacketCodec.build(receiver:"a",sender:"b",id:0x1234,payload:Data("hello".utf8)); let decoded=try PacketStreamDecoder().append(built); XCTAssertEqual(decoded.first?.id,0x1234); XCTAssertEqual(decoded.first?.payload,Data("hello".utf8)) }
    func testCMRoundTrip() throws { let data=CMCodec.encode(target:5,source:3,id:0x0241,payload:Data([1,2])); let decoded=try CMCodec.decodeAll(data); XCTAssertEqual(decoded.first?.messageID,0x0241); XCTAssertEqual(decoded.first?.payload,Data([1,2])) }
}
