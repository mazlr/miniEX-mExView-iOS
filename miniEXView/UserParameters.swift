import Foundation

struct MiniEXFirmwareVersion: Equatable {
    let rawWord: UInt16
    let firmwareCode: UInt16
    let major: Int
    let minor: Int
    let model: Int

    var displayName: String { "\(major).\(String(format: "%02d", minor))" }
    var modelName: String {
        switch model {
        case 1: return "miniEXPLONIX 1"
        case 2: return "miniEXPLONIX 2"
        case 3: return "miniEXPLONIX 3"
        default: return "miniEXPLONIX (model \(model))"
        }
    }
    var dataTypeSize: Int {
        if firmwareCode >= 0x0212 { return 3 }
        if firmwareCode >= 0x0202 { return 2 }
        return 1
    }
    var availableModes: Int {
        switch model {
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 0: return dataTypeSize == 2 ? 2 : 0
        default: return 0
        }
    }
    static func from(word: UInt16) -> MiniEXFirmwareVersion {
        let code = word & 0x1fff
        return .init(rawWord: word, firmwareCode: code, major: Int((code & 0x1f00) >> 8), minor: Int(code & 0xff), model: Int((word >> 13) & 7))
    }
    static func decode(_ data: Data) throws -> MiniEXFirmwareVersion {
        guard data.count == 2 else { throw CodecError.malformed("Firmware reply must contain 2 bytes.") }
        return from(word: UInt16(MiniEXUserParametersCodec.readU16(data, at: 0)))
    }
}

struct MiniEXParameterBounds: Equatable {
    let minimum: [Int]
    let maximum: [Int]
    let scale: [Int]

    init(minimum: [Int], maximum: [Int], scale: [Int]) {
        precondition(minimum.count == 8 && maximum.count == 8 && scale.count == 8)
        self.minimum = minimum; self.maximum = maximum; self.scale = scale
    }
    func rawMinimum(_ parameter: Int) -> Int { minimum[MiniEXUserParametersCodec.boundIndex(for: parameter)] }
    func rawMaximum(_ parameter: Int) -> Int { maximum[MiniEXUserParametersCodec.boundIndex(for: parameter)] }
    func rawScale(_ parameter: Int) -> Int { scale[MiniEXUserParametersCodec.boundIndex(for: parameter)] }
    func displayMinimum(_ parameter: Int) -> Double { MiniEXUserParametersCodec.rawToDisplay(parameter: parameter, raw: rawMinimum(parameter), scale: rawScale(parameter)) }
    func displayMaximum(_ parameter: Int) -> Double { MiniEXUserParametersCodec.rawToDisplay(parameter: parameter, raw: rawMaximum(parameter), scale: rawScale(parameter)) }
    static let defaults = MiniEXParameterBounds(
        minimum: [0, 0, 5, 3, 0, 0, 0, -100],
        maximum: [10000, 2000, 600 * 16, 30 * 16, 5, 5, 255, 100],
        scale: [1, 10, 16, 16, 1, 1, 1, -1]
    )
}

struct MiniEXUserParameters: Equatable {
    var raw: [Int]
    var valid: Int
    init(raw: [Int], valid: Int = 1) { precondition(raw.count == 13); self.raw = raw; self.valid = valid }
    var modeIndex: Int { (raw[MiniEXUserParametersCodec.bitConfigIndex] & MiniEXUserParametersCodec.modeMask) >> MiniEXUserParametersCodec.modeShift }
    func normalized(to bounds: MiniEXParameterBounds) -> MiniEXUserParameters {
        var result = self; let fallback = Self.defaults.raw
        for index in MiniEXUserParametersCodec.editableParameterIndices where !(bounds.rawMinimum(index)...bounds.rawMaximum(index)).contains(result.raw[index]) {
            result.raw[index] = min(max(fallback[index], bounds.rawMinimum(index)), bounds.rawMaximum(index))
        }
        return result
    }
    static let defaults = MiniEXUserParameters(raw: [1000, 200, 600 * 16, 15 * 16, 5, 5, 0x12, 0, 1000, 200, 1000, 200, 0])
}

enum MiniEXUserParametersCodec {
    static let userParameterCount = 13
    static let editableParameterIndices = [0, 1, 2, 3, 4, 5, 8, 9, 10, 11]
    static let bitConfigIndex = 6, userHFIndex = 7
    static let modeMask = 0x0180, modeShift = 7, wifiMask = 0x0001
    static let primaryLanguageMask = 0x000e, primaryLanguageShift = 1
    static let secondaryLanguageMask = 0x0070, secondaryLanguageShift = 4
    private static let parameterToBound = [0, 1, 2, 3, 4, 5, 6, 7, 0, 1, 0, 1, 6]

    static func boundIndex(for parameter: Int) -> Int { precondition((0..<13).contains(parameter)); return parameterToBound[parameter] }
    static func valueCount(dataTypeSize: Int) throws -> Int {
        switch dataTypeSize { case 1: return 8; case 2: return 10; case 3: return 13; default: throw CodecError.malformed("Unsupported parameter type \(dataTypeSize).") }
    }
    static func decodeBounds(_ data: Data) throws -> MiniEXParameterBounds {
        guard data.count == 48 else { throw CodecError.malformed("Parameter limits must contain 48 bytes.") }
        var minimum = Array(repeating: 0, count: 8), maximum = minimum, scale = minimum
        for i in 0..<8 { minimum[i] = readU16(data, at: i * 2); maximum[i] = readU16(data, at: 16 + i * 2); scale[i] = readS16(data, at: 32 + i * 2) }
        for i in 0..<8 where scale[i] < 0 { minimum[i] = signExtend16(minimum[i]); maximum[i] = signExtend16(maximum[i]) }
        return .init(minimum: minimum, maximum: maximum, scale: scale)
    }
    static func encodeValues(_ values: MiniEXUserParameters, dataTypeSize: Int) throws -> Data {
        let count = try valueCount(dataTypeSize: dataTypeSize); var output = Data(repeating: 0, count: (count + 1) * 2)
        for i in 0..<count {
            let value = values.raw[i]
            if i == userHFIndex { guard (-32768...32767).contains(value) else { throw CodecError.malformed("UserHf is outside Int16.") } }
            else { guard (0...65535).contains(value) else { throw CodecError.malformed("Parametr \(i) is outside UInt16.") } }
            writeU16(&output, at: i * 2, value: value)
        }
        let valid = values.valid == 0 ? 1 : values.valid
        guard (0...65535).contains(valid) else { throw CodecError.malformed("Valid flag is outside UInt16.") }
        writeU16(&output, at: count * 2, value: valid); return output
    }
    static func decodeValues(_ data: Data, dataTypeSize: Int) throws -> MiniEXUserParameters {
        let count = try valueCount(dataTypeSize: dataTypeSize), expected = (count + 1) * 2
        guard data.count == expected else { throw CodecError.malformed("Parameters must contain \(expected) bytes.") }
        var raw = MiniEXUserParameters.defaults.raw
        for i in 0..<count { raw[i] = i == userHFIndex ? readS16(data, at: i * 2) : readU16(data, at: i * 2) }
        if count < userParameterCount { for i in count..<userParameterCount { raw[i] = 0 } }
        return .init(raw: raw, valid: readU16(data, at: count * 2))
    }
    static func rawToDisplay(parameter: Int, raw: Int, scale: Int) -> Double {
        let magnitude = abs(scale); guard magnitude != 0 else { return 0 }
        return isDivider(parameter) ? Double(raw) / Double(magnitude) : Double(raw * magnitude)
    }
    static func displayToRaw(parameter: Int, display: Double, scale: Int) -> Int {
        let magnitude = abs(scale); guard magnitude != 0 else { return 0 }; let integral = Int(display)
        return isDivider(parameter) ? integral * magnitude : integral / magnitude
    }
    static func languageID(bitConfig: Int, primary: Bool) -> Int { primary ? (bitConfig & primaryLanguageMask) >> primaryLanguageShift : (bitConfig & secondaryLanguageMask) >> secondaryLanguageShift }
    static func withLanguageID(bitConfig: Int, primary: Bool, languageID: Int) -> Int {
        precondition((0...7).contains(languageID))
        return primary ? (bitConfig & ~primaryLanguageMask) | ((languageID << primaryLanguageShift) & primaryLanguageMask) : (bitConfig & ~secondaryLanguageMask) | ((languageID << secondaryLanguageShift) & secondaryLanguageMask)
    }
    static func readU16(_ data: Data, at offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
    static func readS16(_ data: Data, at offset: Int) -> Int { signExtend16(readU16(data, at: offset)) }
    private static func signExtend16(_ value: Int) -> Int { value & 0x8000 == 0 ? value : value - 0x10000 }
    private static func writeU16(_ data: inout Data, at offset: Int, value: Int) { data[offset] = UInt8(value & 0xff); data[offset + 1] = UInt8((value >> 8) & 0xff) }
    private static func isDivider(_ parameter: Int) -> Bool { parameter == 2 || parameter == 3 }
}
