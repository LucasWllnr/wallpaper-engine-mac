//
//  WEScenePackage.swift
//  Open Wallpaper Engine
//
//  Readers for Wallpaper Engine scene files: scene.pkg archives (PKGV) and .tex
//  textures (TEXV/TEXI/TEXB/TEXS, LZ4, DXT1/3/5, R8, RG88, embedded PNG/JPEG).
//

import CoreGraphics
import Foundation
import ImageIO

enum WESceneError: LocalizedError {
    case badPackage, badTexture(String), unsupported(String)

    var errorDescription: String? {
        switch self {
        case .badPackage: "scene.pkg is damaged."
        case .badTexture(let name): "Texture \(name) could not be read."
        case .unsupported(let what): "Not supported yet: \(what)."
        }
    }
}

/// Little-endian reader over a Data buffer
struct BinaryReader {
    let data: Data
    var offset = 0

    var remaining: Int { data.count - offset }

    mutating func u32() throws -> Int {
        guard remaining >= 4 else { throw WESceneError.badPackage }
        let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        offset += 4
        return Int(UInt32(littleEndian: value))
    }

    mutating func i32() throws -> Int { Int(Int32(truncatingIfNeeded: try u32())) }

    mutating func f32() throws -> Double {
        Double(Float(bitPattern: UInt32(truncatingIfNeeded: try u32())))
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WESceneError.badPackage }
        defer { offset += count }
        return data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + count)
    }

    mutating func string(_ count: Int) throws -> String {
        String(decoding: try bytes(count), as: UTF8.self)
    }

    /// 8-character tag followed by a NUL ("TEXB0004")
    mutating func tag() throws -> String {
        String(try string(9).prefix(8))
    }
}

/// Files of a scene wallpaper, from scene.pkg or from the folder itself
struct WEScenePackage {
    let directory: URL
    private var files = [String: Data]()

    /// `sceneFile` names the archive too: "gifscene.json" lives in "gifscene.pkg"
    init(directory: URL, sceneFile: String = "scene.json") throws {
        self.directory = directory
        let archive = (sceneFile as NSString).deletingPathExtension + ".pkg"
        for name in [archive, "scene.pkg"] {
            if let data = try? Data(contentsOf: directory.appending(path: name), options: .mappedIfSafe) {
                files = try Self.parse(data)
                break
            }
        }
    }

    static func parse(_ data: Data) throws -> [String: Data] {
        var reader = BinaryReader(data: Data(data))
        _ = try reader.string(try reader.u32()) // PKGV00xx
        let count = try reader.u32()
        var entries = [(name: String, offset: Int, size: Int)]()
        for _ in 0..<count {
            let name = try reader.string(try reader.u32())
            entries.append((name, try reader.u32(), try reader.u32()))
        }
        let base = reader.offset
        var files = [String: Data]()
        for entry in entries where base + entry.offset + entry.size <= reader.data.count {
            let start = reader.data.startIndex + base + entry.offset
            files[entry.name] = reader.data.subdata(in: start ..< start + entry.size)
        }
        return files
    }

    var fileNames: [String] { Array(files.keys) }

    func data(_ path: String) -> Data? {
        let key = path.replacingOccurrences(of: "\\", with: "/")
        if let data = files[key] { return data }
        if let data = try? Data(contentsOf: directory.appending(path: key)) { return data }
        // Presets, built-in particle textures and effect files ship with Wallpaper Engine
        return WEAssets.directory.flatMap { try? Data(contentsOf: $0.appending(path: key)) }
    }

    func json(_ path: String) -> [String: Any]? {
        guard let data = data(path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .json5Allowed])) as? [String: Any]
    }
}

// MARK: - Textures

struct WETexture {
    struct Frame {
        var imageIndex: Int
        var rect: CGRect
        var duration: Double
    }

    /// Full first mip of every image (texture size), rows top to bottom
    var images: [CGImage]
    var imageSize: CGSize
    var frames: [Frame]

    /// Visible part of the texture (textures are padded to power-of-two sizes)
    var croppedImage: CGImage? {
        guard let image = images.first else { return nil }
        let rect = CGRect(x: 0, y: 0, width: min(imageSize.width, CGFloat(image.width)), height: min(imageSize.height, CGFloat(image.height)))
        return image.cropping(to: rect) ?? image
    }

    /// One cropped image per sprite frame, with its duration
    var animation: [(CGImage, Double)] {
        frames.compactMap { frame in
            guard frame.imageIndex < images.count, let image = images[frame.imageIndex].cropping(to: frame.rect) else { return nil }
            return (image, max(frame.duration, 0.01))
        }
    }

    static func decode(_ data: Data, name: String = "") throws -> WETexture {
        var r = BinaryReader(data: Data(data))
        guard try r.tag() == "TEXV0005", try r.tag() == "TEXI0001" else { throw WESceneError.badTexture(name) }
        let format = try r.u32()
        _ = try r.u32() // flags
        _ = try r.u32(); _ = try r.u32() // texture width/height
        let imageWidth = try r.u32(), imageHeight = try r.u32()
        _ = try r.u32()

        let container = try r.tag()
        guard container.hasPrefix("TEXB"), let version = Int(container.suffix(4)) else { throw WESceneError.badTexture(name) }
        let imageCount = try r.u32()
        var freeImageFormat = -1
        if version >= 3 { freeImageFormat = try r.i32() }
        if version >= 4, try r.u32() != 0 { throw WESceneError.unsupported("video texture") }

        var images = [CGImage]()
        for _ in 0..<imageCount {
            let mipCount = try r.u32()
            for mip in 0..<mipCount {
                let width = try r.u32(), height = try r.u32()
                var bytes: Data
                if version >= 2 {
                    let compressed = try r.u32() != 0
                    let size = try r.u32()
                    let stored = try r.u32()
                    bytes = try r.bytes(stored)
                    if compressed { bytes = try LZ4.decompressBlock(bytes, size: size) }
                } else {
                    bytes = try r.bytes(try r.u32())
                }
                guard mip == 0 else { continue }
                if freeImageFormat != -1 {
                    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                    else { throw WESceneError.badTexture(name) }
                    images.append(image)
                } else {
                    images.append(try makeImage(bytes, width: width, height: height, format: format, name: name))
                }
            }
        }
        guard !images.isEmpty else { throw WESceneError.badTexture(name) }

        var frames = [Frame]()
        if r.remaining >= 13, let sprite = try? r.tag(), sprite.hasPrefix("TEXS"), let spriteVersion = Int(sprite.suffix(4)) {
            let frameCount = try r.u32()
            if spriteVersion >= 3 { _ = try r.u32(); _ = try r.u32() }
            for _ in 0..<frameCount {
                let index = try r.u32()
                let duration = try r.f32()
                func value() throws -> Double { spriteVersion == 1 ? Double(try r.u32()) : try r.f32() }
                let x = try value(), y = try value(), width = try value()
                _ = try value(); _ = try value()
                let height = try value()
                frames.append(Frame(imageIndex: index, rect: CGRect(x: x, y: y, width: width, height: height), duration: duration))
            }
        }
        return WETexture(images: images,
                         imageSize: CGSize(width: imageWidth, height: imageHeight),
                         frames: frames)
    }

    private static func makeImage(_ data: Data, width: Int, height: Int, format: Int, name: String) throws -> CGImage {
        let source = [UInt8](data)
        let rgba: [UInt8]
        switch format {
        case 0: // RGBA8888
            guard source.count >= width * height * 4 else { throw WESceneError.badTexture(name) }
            rgba = Array(source.prefix(width * height * 4))
        case 4, 6, 7: // DXT5, DXT3, DXT1
            rgba = DXT.decode(source, width: width, height: height, format: format)
        case 8: // RG88: luminance + alpha
            guard source.count >= width * height * 2 else { throw WESceneError.badTexture(name) }
            var out = [UInt8](repeating: 0, count: width * height * 4)
            for i in 0..<(width * height) {
                out[i * 4] = source[i * 2]; out[i * 4 + 1] = source[i * 2]; out[i * 4 + 2] = source[i * 2]
                out[i * 4 + 3] = source[i * 2 + 1]
            }
            rgba = out
        case 9: // R8: the single channel is coverage (particle sprites, masks) -> white with that alpha
            guard source.count >= width * height else { throw WESceneError.badTexture(name) }
            var out = [UInt8](repeating: 255, count: width * height * 4)
            for i in 0..<(width * height) { out[i * 4 + 3] = source[i] }
            rgba = out
        default:
            throw WESceneError.unsupported("texture format \(format)")
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw WESceneError.badTexture(name) }
        return image
    }
}

// MARK: - LZ4 (block format)

enum LZ4 {
    static func decompressBlock(_ data: Data, size: Int) throws -> Data {
        let source = [UInt8](data)
        var out = [UInt8](repeating: 0, count: size)
        let written: Int = try source.withUnsafeBufferPointer { src in
            try out.withUnsafeMutableBufferPointer { dst in
                var p = 0, o = 0
                while p < src.count {
                    let token = Int(src[p]); p += 1
                    var literals = token >> 4
                    if literals == 15 {
                        while p < src.count { let b = Int(src[p]); p += 1; literals += b; if b != 255 { break } }
                    }
                    guard p + literals <= src.count, o + literals <= dst.count else { throw WESceneError.badPackage }
                    if literals > 0 {
                        (dst.baseAddress! + o).update(from: src.baseAddress! + p, count: literals)
                    }
                    p += literals; o += literals
                    if p >= src.count { break }
                    guard p + 1 < src.count else { throw WESceneError.badPackage }
                    let distance = Int(src[p]) | Int(src[p + 1]) << 8; p += 2
                    var length = token & 15
                    if length == 15 {
                        while p < src.count { let b = Int(src[p]); p += 1; length += b; if b != 255 { break } }
                    }
                    length += 4
                    let start = o - distance
                    guard distance > 0, start >= 0, o + length <= dst.count else { throw WESceneError.badPackage }
                    // Overlapping matches repeat the last `distance` bytes: copy from `start` in chunks
                    // that double each time (always a multiple of the period, never overlapping)
                    var copied = 0
                    while copied < length {
                        let chunk = min(length - copied, distance + copied)
                        (dst.baseAddress! + o + copied).update(from: dst.baseAddress! + start, count: chunk)
                        copied += chunk
                    }
                    o += length
                }
                return o
            }
        }
        return Data(out.prefix(written))
    }
}

// MARK: - DXT (BC1/BC2/BC3)

enum DXT {
    static func decode(_ source: [UInt8], width: Int, height: Int, format: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let blockSize = format == 7 ? 8 : 16
        let blocksX = max(1, (width + 3) / 4), blocksY = max(1, (height + 3) / 4)
        var colors = [[UInt8]](repeating: [0, 0, 0, 255], count: 4)
        var alphas = [UInt8](repeating: 255, count: 16)

        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                let b = (by * blocksX + bx) * blockSize
                guard b + blockSize <= source.count else { return out }
                let c = b + (format == 7 ? 0 : 8)

                // Alpha
                if format == 6 { // DXT3: explicit 4-bit alpha
                    for i in 0..<16 {
                        let byte = source[b + i / 2]
                        alphas[i] = (i % 2 == 0 ? byte & 0x0F : byte >> 4) * 17
                    }
                } else if format == 4 { // DXT5: interpolated alpha
                    let a0 = Int(source[b]), a1 = Int(source[b + 1])
                    var table = [a0, a1, 0, 0, 0, 0, 0, 0]
                    if a0 > a1 {
                        for i in 1...6 { table[i + 1] = ((7 - i) * a0 + i * a1) / 7 }
                    } else {
                        for i in 1...4 { table[i + 1] = ((5 - i) * a0 + i * a1) / 5 }
                        table[6] = 0; table[7] = 255
                    }
                    var bits: UInt64 = 0
                    for i in 0..<6 { bits |= UInt64(source[b + 2 + i]) << (8 * UInt64(i)) }
                    for i in 0..<16 { alphas[i] = UInt8(table[Int((bits >> (3 * UInt64(i))) & 7)]) }
                } else {
                    for i in 0..<16 { alphas[i] = 255 }
                }

                // Color
                let c0 = Int(source[c]) | Int(source[c + 1]) << 8
                let c1 = Int(source[c + 2]) | Int(source[c + 3]) << 8
                func rgb(_ v: Int) -> [Int] { [(v >> 11 & 31) * 255 / 31, (v >> 5 & 63) * 255 / 63, (v & 31) * 255 / 31] }
                let k0 = rgb(c0), k1 = rgb(c1)
                colors[0] = [UInt8(k0[0]), UInt8(k0[1]), UInt8(k0[2]), 255]
                colors[1] = [UInt8(k1[0]), UInt8(k1[1]), UInt8(k1[2]), 255]
                if c0 > c1 || format != 7 {
                    colors[2] = (0..<3).map { UInt8((2 * k0[$0] + k1[$0]) / 3) } + [255]
                    colors[3] = (0..<3).map { UInt8((k0[$0] + 2 * k1[$0]) / 3) } + [255]
                } else {
                    colors[2] = (0..<3).map { UInt8((k0[$0] + k1[$0]) / 2) } + [255]
                    colors[3] = [0, 0, 0, 0]
                }
                let indices = UInt32(source[c + 4]) | UInt32(source[c + 5]) << 8 | UInt32(source[c + 6]) << 16 | UInt32(source[c + 7]) << 24

                for py in 0..<4 {
                    let y = by * 4 + py
                    guard y < height else { break }
                    for px in 0..<4 {
                        let x = bx * 4 + px
                        guard x < width else { break }
                        let i = py * 4 + px
                        let color = colors[Int(indices >> (2 * UInt32(i)) & 3)]
                        let o = (y * width + x) * 4
                        out[o] = color[0]; out[o + 1] = color[1]; out[o + 2] = color[2]
                        out[o + 3] = format == 7 ? color[3] : alphas[i]
                    }
                }
            }
        }
        return out
    }
}
