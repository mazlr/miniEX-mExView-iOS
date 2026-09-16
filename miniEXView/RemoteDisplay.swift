import Foundation
import UIKit

struct RCCommand {
    let id: UInt8
    let payload: [UInt8]
}

enum RCStream {
    static func decode(_ input: Data) throws -> (UInt16, [RCCommand]) {
        let bytes = [UInt8](input)
        guard bytes.count >= 2 else { throw CodecError.malformed("RC stream nemá pořadové číslo.") }
        let sequence = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        var commands: [RCCommand] = []
        var offset = 2
        while offset < bytes.count {
            let length = Int(bytes[offset])
            guard length >= 1, offset + length < bytes.count else {
                throw CodecError.malformed("RC příkaz na pozici \(offset) je neúplný.")
            }
            let id = bytes[offset + 1]
            let payload = Array(bytes[(offset + 2)..<(offset + length + 1)])
            let required: Int?
            switch id {
            case 0x40, 0x4b, 0x4f: required = 1
            case 0x41, 0x42, 0x43: required = 2
            case 0x44, 0x45: required = 0
            case 0x46: required = 3
            case 0x49: required = 6
            case 0x4a, 0x4c, 0x4d: required = 4
            default: required = nil
            }
            if let required, payload.count != required {
                throw CodecError.malformed("RC příkaz 0x\(String(id, radix: 16)) má \(payload.count) bajtů, očekává \(required).")
            }
            if id == 0x48 && payload.count < 3 { throw CodecError.malformed("RC text nemá souřadnice a font.") }
            commands.append(.init(id: id, payload: payload))
            offset += length + 1
        }
        return (sequence, commands)
    }
}

struct RCBitmap: Decodable {
    let width: Int
    let height: Int
    let fragments: Int
    let type: String
    let data: Data
}

struct RCFont: Decodable {
    let width: Int
    let height: Int
    let first: Int
    let last: Int
    let indexes: [Int]
    let glyphs: [Data]
    func glyph(_ code: UInt8) -> Data? {
        let value = Int(code)
        let slot = (first...last).contains(value) ? value - first + 1 : 0
        guard indexes.indices.contains(slot), glyphs.indices.contains(indexes[slot]) else { return nil }
        return glyphs[indexes[slot]]
    }
}

struct RCResources: Decodable {
    var bitmaps: [RCBitmap]
    let fonts: [RCFont]
    let bargraphs: [RCBitmap]
    static func load(language: String = "English") throws -> RCResources {
        guard let url = Bundle.main.url(forResource: "EnglishRC", withExtension: "json") else {
            throw CodecError.malformed("Chybí anglické RC prostředky.")
        }
        var resources = try JSONDecoder().decode(RCResources.self, from: Data(contentsOf: url))
        if language != "English" {
            guard let localized = Bundle.main.url(forResource: "LocalizedRC", withExtension: "json") else {
                throw CodecError.malformed("Missing localized RC bitmaps")
            }
            let catalog = try JSONDecoder().decode([String: [String: RCBitmap]].self, from: Data(contentsOf: localized))
            if let overrides = catalog[language] {
                for (key, bitmap) in overrides {
                    if let index = Int(key), resources.bitmaps.indices.contains(index) { resources.bitmaps[index] = bitmap }
                }
            }
        }
        return resources
    }
}

final class RCDisplay {
    let width = 160
    let height = 128
    private(set) var pixels = [UInt32](repeating: 0xff000000, count: 160 * 128)
    private let resources: RCResources
    private var backColor = 0
    private var drawColor = 0xffff
    private var bmpColor = 0xffff
    private var fontIndex = 0
    private var bargraphLastColumn = -1
    private var bargraphMax = -1
    private var bargraphLastMax = -1
    private let redGray: [Int] = [0x0000,0xa55a,0x4ba5,0xefff,0x0050,0xa55a,0x4bf5,0xefff,0x00a8,0xa5fa,0x4bad,0xefff,0x00f8,0xa5fa,0x4bfd,0xefff]
    private let redGrayInactive: [Int] = [0x0000,0xaa72,0x77ad,0xffff,0xaa72,0x77ad,0xffff,0xffff,0x77ad,0xffff,0xffff,0xffff,0x0000,0xaa72,0x77ad,0xffff]

    init(resources: RCResources) { self.resources = resources }

    func clear() {
        pixels = [UInt32](repeating: 0xff000000, count: width * height)
        bargraphLastColumn = -1; bargraphMax = -1; bargraphLastMax = -1
    }

    func apply(_ commands: [RCCommand]) {
        for command in commands { apply(command) }
    }

    private func apply(_ command: RCCommand) {
        let d = command.payload
        switch command.id {
        case 0x40: if resources.fonts.indices.contains(Int(d[0])) { fontIndex = Int(d[0]) }
        case 0x41: drawColor = word(d)
        case 0x42: bmpColor = word(d)
        case 0x43: backColor = word(d)
        case 0x44: pixels = [UInt32](repeating: rgb(backColor), count: pixels.count); clearBargraph()
        case 0x45: clearBargraph()
        case 0x46:
            if let bitmap = bitmap(Int(d[0])) { fill(Int(d[1]), Int(d[1]) + bitmap.width, Int(d[2]), Int(d[2]) + bitmap.height, backColor) }
        case 0x48: drawText(x: Int(d[0]), y: Int(d[1]), font: Int(d[2]), text: d.dropFirst(3))
        case 0x49: fill(Int(d[0]), Int(d[1]), Int(d[2]), Int(d[3]), word(d, at: 4))
        case 0x4a: fill(Int(d[0]), Int(d[1]), Int(d[2]), Int(d[3]), backColor)
        case 0x4b: drawBargraph(Int(Int8(bitPattern: d[0])))
        case 0x4c: if let bitmap = bitmap(Int(d[0])) { drawBitmap(bitmap, x: Int(d[1]), y: Int(d[2]), fragment: Int(d[3])) }
        case 0x4d:
            if let bitmap = bitmap(Int(d[0])) {
                let left = Int(d[1]) + max(0, (Int(d[2]) - Int(d[1]) + 1 - bitmap.width) / 2)
                fill(Int(d[1]), left - 1, Int(d[3]), Int(d[3]) + bitmap.height - 1, backColor)
                drawBitmap(bitmap, x: left, y: Int(d[3]), fragment: 0)
                fill(left + bitmap.width, Int(d[2]), Int(d[3]), Int(d[3]) + bitmap.height - 1, backColor)
            }
        case 0x4f:
            bargraphLastColumn = resources.bargraphs.count - 1
            bargraphMax = max(-1, min(Int(Int8(bitPattern: d[0])), resources.bargraphs.count - 1))
            bargraphLastMax = -1
        default: break
        }
    }

    func image() -> UIImage? {
        let data = pixels.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<UInt32>.size)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: width, height: height, bitsPerComponent: 8,
                                    bitsPerPixel: 32, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                        .union(.byteOrder32Little),
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func bitmap(_ id: Int) -> RCBitmap? { resources.bitmaps.indices.contains(id) ? resources.bitmaps[id] : nil }
    private func word(_ bytes: [UInt8], at offset: Int = 0) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
    private func set(_ x: Int, _ y: Int, _ color: UInt32) { if (0..<width).contains(x) && (0..<height).contains(y) { pixels[y * width + x] = color } }
    private func fill(_ x1: Int, _ x2: Int, _ y1: Int, _ y2: Int, _ color: Int) {
        guard x1 <= x2, y1 <= y2 else { return }
        let left = max(0, min(x1, x2)), right = min(width - 1, max(x1, x2))
        let top = max(0, min(y1, y2)), bottom = min(height - 1, max(y1, y2))
        guard left <= right, top <= bottom else { return }
        let value = rgb(color)
        for y in top...bottom { for x in left...right { set(x, y, value) } }
    }
    private func drawText(x: Int, y: Int, font: Int, text: ArraySlice<UInt8>) {
        guard resources.fonts.indices.contains(font) else { return }
        fontIndex = font
        let f = resources.fonts[font]
        var cursor = x
        for byte in text {
            if byte == 0 { break }
            if let glyph = f.glyph(byte), glyph.count >= f.width * f.height {
                for row in 0..<f.height {
                    for column in 0..<f.width {
                        set(cursor + column, y + row, rgb(glyph[row * f.width + column] == 0 ? backColor : drawColor))
                    }
                }
            }
            cursor += f.width
        }
    }
    private func drawBitmap(_ bitmap: RCBitmap, x: Int, y: Int, fragment: Int) {
        guard (0..<bitmap.fragments).contains(fragment), bitmap.type != "REDWHITE4_RED" else { return }
        let pixelCount = bitmap.width * bitmap.height
        let bytesPerFragment: Int
        switch bitmap.type {
        case "COLOR16": bytesPerFragment = pixelCount * 2
        case "COLOR8": bytesPerFragment = pixelCount
        case "MONO": bytesPerFragment = (pixelCount + 7) / 8
        case "CGRAY2": bytesPerFragment = (pixelCount + 3) / 4
        default: bytesPerFragment = (pixelCount + 1) / 2
        }
        let base = fragment * bytesPerFragment
        for pixel in 0..<pixelCount {
            let row = pixel / bitmap.width, column = pixel % bitmap.width
            let value: UInt32
            let index: Int
            switch bitmap.type {
            case "COLOR16":
                index = base + pixel * 2
                guard index + 1 < bitmap.data.count else { continue }
                value = rgb(Int(bitmap.data[index]) | Int(bitmap.data[index + 1]) << 8)
            case "COLOR8":
                index = base + pixel
                guard index < bitmap.data.count else { continue }
                value = color8(bitmap.data[index])
            case "MONO":
                index = base + pixel / 8
                guard index < bitmap.data.count else { continue }
                value = rgb((Int(bitmap.data[index]) & (0x80 >> (pixel % 8))) == 0 ? backColor : bmpColor)
            case "CGRAY2":
                index = base + pixel / 4
                guard index < bitmap.data.count else { continue }
                value = tintGray((Int(bitmap.data[index]) >> (6 - 2 * (pixel % 4))) & 3, max: 3)
            case "CGRAY4", "REDWHITE4", "REDWHITE4_INACTIVE":
                index = base + pixel / 2
                guard index < bitmap.data.count else { continue }
                let nibble = pixel % 2 == 0 ? Int(bitmap.data[index]) >> 4 : Int(bitmap.data[index]) & 15
                if bitmap.type == "CGRAY4" { value = tintGray(nibble, max: 15) }
                else { value = rgb(bitmap.type == "REDWHITE4" ? redGray[nibble] : redGrayInactive[nibble]) }
            default: continue
            }
            set(x + column, y + row, value)
        }
    }
    private func drawBargraph(_ requested: Int) {
        let columns = resources.bargraphs
        guard !columns.isEmpty else { return }
        let current = max(-1, min(requested, columns.count - 1))
        bargraphMax = max(bargraphMax, current)
        let previous = bmpColor
        func drawColumn(_ index: Int, _ tint: Int) {
            guard columns.indices.contains(index) else { return }
            bmpColor = tint
            drawBitmap(columns[index], x: 2 + index * 6, y: 90 - columns[index].height, fragment: 0)
        }
        if bargraphLastColumn < current {
            for index in (bargraphLastColumn + 1)...current { drawColumn(index, 0) }
        } else {
            if current + 1 < bargraphMax { for index in (current + 1)..<bargraphMax { drawColumn(index, 48) } }
            if bargraphMax >= 0 { drawColumn(bargraphMax, 0) }
            if bargraphMax + 1 <= bargraphLastMax {
                for index in (bargraphMax + 1)...bargraphLastMax { clearBargraphColumn(index) }
            }
        }
        bargraphLastColumn = current
        bargraphLastMax = bargraphMax
        bmpColor = previous
    }
    private func clearBargraph() {
        for index in resources.bargraphs.indices { clearBargraphColumn(index) }
        bargraphLastColumn = -1; bargraphMax = -1; bargraphLastMax = -1
    }
    private func clearBargraphColumn(_ index: Int) {
        let column = resources.bargraphs[index], x = 2 + index * 6
        fill(x, x + column.width - 1, 90 - column.height, 89, 0)
    }
    private func color8(_ byte: UInt8) -> UInt32 {
        let n = Int(byte), r = ((n >> 5) * 255) / 7, g = (((n >> 2) & 7) * 255) / 7, b = ((n & 3) * 255) / 3
        if bmpColor == 0 { return argb(r, g, b) }
        return tintGray((r * 30 + g * 59 + b * 11) / 100, max: 255)
    }
    private func tintGray(_ level: Int, max maximum: Int) -> UInt32 {
        let gray = min(maximum, Swift.max(0, level)) * 255 / maximum
        if bmpColor == 0 { return argb(gray, gray, gray) }
        let tint = rgb(bmpColor)
        return argb(Int((tint >> 16) & 255) * gray / 255, Int((tint >> 8) & 255) * gray / 255, Int(tint & 255) * gray / 255)
    }
    private func rgb(_ color: Int) -> UInt32 {
        let r = (color & 0x00f8) | ((color & 0x00e0) >> 5)
        let g = ((color & 0xe000) >> 11) | ((color & 0x0007) << 5) | ((color & 0x0006) >> 1)
        let b = ((color & 0x1f00) >> 5) | ((color & 0x1c00) >> 10)
        return argb(r, g, b)
    }
    private func argb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 { 0xff000000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }
}
