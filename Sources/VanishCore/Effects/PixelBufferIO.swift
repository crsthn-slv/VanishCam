import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small helpers for IOSurface-backed, Metal-compatible pixel buffers and PNG I/O.
public enum PixelBufferIO {
    /// New IOSurface-backed, Metal-compatible buffer (BGRA by default).
    public static func make(width: Int, height: Int,
                            format: OSType = kCVPixelFormatType_32BGRA) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &pb)
        return pb
    }

    /// Draws into a locked BGRA buffer through a CGContext.
    static func withContext(_ pb: CVPixelBuffer, alpha: Bool = false, _ body: (CGContext) -> Void) throws {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else {
            throw EffectError.io("expected BGRA pixel buffer")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb),
                                  width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                                    | (alpha ? CGImageAlphaInfo.premultipliedFirst : .noneSkipFirst).rawValue) else {
            throw EffectError.io("cannot create bitmap context")
        }
        body(ctx)
    }

    /// Snapshot of a BGRA buffer as a CGImage (copies pixels).
    public static func cgImage(from pb: CVPixelBuffer, alpha: Bool = false) throws -> CGImage {
        var image: CGImage?
        try withContext(pb, alpha: alpha) { image = $0.makeImage() }
        guard let image else { throw EffectError.io("makeImage failed") }
        return image
    }

    public static func writePNG(_ pb: CVPixelBuffer, to url: URL, alpha: Bool = false) throws {
        let image = try cgImage(from: pb, alpha: alpha)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw EffectError.io("cannot create \(url.path)") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw EffectError.io("cannot write \(url.path)") }
    }

    /// Loads any ImageIO-readable file, scaled and centre-cropped to fill width x height (aspect fill).
    /// `scale` / `offset` (fraction of the frame, y-down) move the aspect-filled image about the centre.
    public static func loadImage(at url: URL, width: Int, height: Int, mirrored: Bool = false,
                                 scale: Double = 1, offset: CGPoint = .zero) throws -> CVPixelBuffer {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw EffectError.io("cannot read image \(url.path)") }
        guard let pb = make(width: width, height: height) else { throw EffectError.io("buffer alloc failed") }
        let fill = max(Double(width) / Double(image.width), Double(height) / Double(image.height)) * scale
        let w = Double(image.width) * fill, h = Double(image.height) * fill
        let cx = Double(width) * (0.5 + (mirrored ? -offset.x : offset.x)), cy = Double(height) * (0.5 - offset.y)   // CG is y-up
        try withContext(pb) { ctx in
            ctx.interpolationQuality = .high
            if mirrored { ctx.translateBy(x: CGFloat(width), y: 0); ctx.scaleBy(x: -1, y: 1) }
            ctx.draw(image, in: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
        }
        // skip-alpha contexts leave the alpha byte undefined; consumers (vc_bgmem) read it
        CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height { for x in 0..<width { base[y * bpr + x * 4 + 3] = 255 } }
        return pb
    }

    /// Fills a BGRA buffer with a solid colour (0-255 components). Handy for tests and placeholders.
    public static func fill(_ pb: CVPixelBuffer, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<CVPixelBufferGetHeight(pb) {
            let row = base + y * bpr
            for x in 0..<CVPixelBufferGetWidth(pb) {
                row[x * 4] = b; row[x * 4 + 1] = g; row[x * 4 + 2] = r; row[x * 4 + 3] = a
            }
        }
    }
}
