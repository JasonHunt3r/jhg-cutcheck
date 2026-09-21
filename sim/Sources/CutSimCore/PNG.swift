import Foundation

/// Minimal PNG writer so a preview needs no image framework.
///
/// Uses stored (uncompressed) deflate blocks. The files are larger than a
/// real encoder would produce, but this is a preview written once and looked
/// at once, and it keeps the core free of dependencies.
public enum PNG {

    public static func write(rgb: [UInt8], width: Int, height: Int, to path: String) throws {
        precondition(rgb.count == width * height * 3, "pixel buffer size mismatch")

        var raw = [UInt8]()
        raw.reserveCapacity(height * (width * 3 + 1))
        for y in 0..<height {
            raw.append(0)   // filter type: none
            raw.append(contentsOf: rgb[(y * width * 3)..<((y + 1) * width * 3)])
        }

        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var ihdr = Data()
        ihdr.append(be32(UInt32(width)))
        ihdr.append(be32(UInt32(height)))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])   // 8-bit, truecolour
        out.append(chunk("IHDR", ihdr))
        out.append(chunk("IDAT", zlibStored(raw)))
        out.append(chunk("IEND", Data()))

        try out.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - plumbing

    static func be32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
              UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    static func chunk(_ tag: String, _ body: Data) -> Data {
        var d = be32(UInt32(body.count))
        let tagged = Data(tag.utf8) + body
        d.append(tagged)
        d.append(be32(crc32(tagged)))
        return d
    }

    static func zlibStored(_ bytes: [UInt8]) -> Data {
        var d = Data([0x78, 0x01])
        var i = 0
        if bytes.isEmpty { d.append(contentsOf: [0x01, 0x00, 0x00, 0xFF, 0xFF]) }
        while i < bytes.count {
            let n = min(65535, bytes.count - i)
            let final: UInt8 = (i + n >= bytes.count) ? 1 : 0
            d.append(final)
            d.append(UInt8(n & 0xFF)); d.append(UInt8((n >> 8) & 0xFF))
            let inv = ~UInt16(n)
            d.append(UInt8(inv & 0xFF)); d.append(UInt8((inv >> 8) & 0xFF))
            d.append(contentsOf: bytes[i..<(i + n)])
            i += n
        }
        d.append(be32(adler32(bytes)))
        return d
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}

public extension HeightField {
    /// Top-down depth map. Pale is untouched surface, darker is deeper,
    /// near-black is cut clean through. +Y is up, matching how the part
    /// sits on the bed.
    func writePreview(to path: String, maxPixels: Int = 1600) throws -> (Int, Int, Int) {
        let f = max(1, Int((Double(max(nx, ny)) / Double(maxPixels)).rounded(.up)))
        let ow = nx / f, oh = ny / f
        var rgb = [UInt8](repeating: 0, count: ow * oh * 3)
        let depth = top - bottom

        for oy in 0..<oh {
            for ox in 0..<ow {
                // Minimum of each block, not the mean: a cut one cell wide
                // is exactly what the preview exists to show.
                var v = Float.greatestFiniteMagnitude
                for by in 0..<f {
                    let iy = oy * f + by
                    if iy >= ny { continue }
                    for bx in 0..<f {
                        let ix = ox * f + bx
                        if ix >= nx { continue }
                        v = min(v, h[iy * nx + ix])
                    }
                }
                let norm = max(0, min(1, (Double(v) - bottom) / depth))
                let cutThrough = Double(v) <= bottom + 1e-6
                // Flip vertically so +Y is up.
                let o = ((oh - 1 - oy) * ow + ox) * 3
                rgb[o]     = cutThrough ? 20 : UInt8(40 + 200 * norm)
                rgb[o + 1] = cutThrough ? 20 : UInt8(30 + 195 * norm)
                rgb[o + 2] = cutThrough ? 28 : UInt8(25 + 175 * norm)
            }
        }
        try PNG.write(rgb: rgb, width: ow, height: oh, to: path)
        return (ow, oh, f)
    }
}
