import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal

// Smoke-and-log substitution and teleport effects. GPU does the person/plate mix (vc_blend); Core Graphics draws
// the overlay (ellipses, arcs, lines, the log sprite).
// Pixel sizes assume a 720p frame; Teleport line widths/glow scale with height / 720.

/// Assets (log sprite, sounds): app bundle Resources, else the repo Assets/ folder (CLI, tests). Missing = skipped.
public enum Assets {
    public static func url(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: nil) { return u }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/\(name)")
        return FileManager.default.fileExists(atPath: src.path) ? src : nil
    }
}

/// Shared GPU pass: mix(plate*exposure, frame, mask*personAlpha) + optional flash.
final class BlendPass {
    private let pipeline: MTLComputePipelineState
    init(pipelines: PipelineCache) throws { pipeline = try pipelines.compute("vc_blend", source: "") }

    func encode(_ cb: MTLCommandBuffer, frame: MTLTexture, plate: MTLTexture, mask: MTLTexture, output: MTLTexture,
                personAlpha: Float, flash: Float, exposure: SIMD3<Float>) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        var p = (personAlpha, flash, Float(0), Float(0))
        var e = SIMD4<Float>(exposure, 0)
        [frame, plate, mask, output].enumerated().forEach { enc.setTexture($1, index: $0) }
        enc.setBytes(&p, length: 16, index: 0)
        enc.setBytes(&e, length: 16, index: 1)
        enc.dispatchPerPixel(pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }
}

/// Mask helpers (OneComponent8, covers the whole frame; returns normalised, y-down).
enum MaskTools {
    static func box(_ m: CVPixelBuffer?, threshold: UInt8) -> CGRect? {
        guard let m, CVPixelBufferGetPixelFormatType(m) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(m, .readOnly); defer { CVPixelBufferUnlockBaseAddress(m, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(m)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(m), h = CVPixelBufferGetHeight(m), bpr = CVPixelBufferGetBytesPerRow(m)
        var x0 = w, x1 = -1, y0 = h, y1 = -1
        for y in 0..<h { let row = base + y * bpr
            for x in 0..<w where row[x] > threshold { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
        guard x1 >= x0 else { return nil }
        return CGRect(x: CGFloat(x0) / CGFloat(w), y: CGFloat(y0) / CGFloat(h),
                      width: CGFloat(x1 - x0 + 1) / CGFloat(w), height: CGFloat(y1 - y0 + 1) / CGFloat(h))
    }

    static func image(_ m: CVPixelBuffer?) -> CGImage? {
        guard let m, CVPixelBufferGetPixelFormatType(m) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(m, .readOnly); defer { CVPixelBufferUnlockBaseAddress(m, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(m) else { return nil }
        let w = CVPixelBufferGetWidth(m), h = CVPixelBufferGetHeight(m), bpr = CVPixelBufferGetBytesPerRow(m)
        guard let provider = CGDataProvider(data: Data(bytes: base, count: bpr * h) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: bpr,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// numpy default_rng stand-in: deterministic per seed so the smoke shape is stable across frames.
struct SeededRNG {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> Double {   // SplitMix64 -> [0, 1)
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

private func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}

// MARK: - Substitution (smoke puff, a log takes your place)

public final class SubstitutionEffect: Effect {
    public let kind: EffectKind = .substitution
    public let duration: Double = 1.45          // EFFECT_SECONDS
    public let returnDuration: Double = 0.001   // original: reappear is an instant cut
    public var exposure = SIMD3<Float>(1, 1, 1)
    public var hasOverlay: Bool { true }

    private let blend: BlendPass
    private let sprite: CGImage?
    private var anchor: (cx: Double, cy: Double, size: Double)?
    private var lastTime: Float = .infinity

    public init(pipelines: PipelineCache) throws {
        blend = try BlendPass(pipelines: pipelines)
        sprite = Assets.url("log.png").flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    public func encode(into cb: MTLCommandBuffer, frame: MTLTexture, plate: MTLTexture, mask: MTLTexture,
                       progress: Float, time: Float, reverse: Bool, output: MTLTexture) {
        // person fades out over the first 0.13 s, then plate only
        let alpha: Float = reverse ? 1 : max(0, 1 - max(0.04, time) / 0.13)
        blend.encode(cb, frame: frame, plate: plate, mask: mask, output: output, personAlpha: alpha, flash: 0, exposure: exposure)
    }

    public func encodeSteady(into cb: MTLCommandBuffer, frame: MTLTexture, plate: MTLTexture, time: Float, output: MTLTexture) {
        blend.encode(cb, frame: plate, plate: plate, mask: plate, output: output, personAlpha: 0, flash: 0, exposure: exposure)
    }

    public func drawOverlay(in ctx: CGContext, width: Int, height: Int, mask: CVPixelBuffer?,
                            time: Float, reverse: Bool, steady: Bool) {
        let H = Double(height)
        if steady {
            if let a = anchor { drawLog(ctx, landed(a, H), opacity: 1, scale: 1) }
            return
        }
        if reverse { return }
        if time < lastTime || anchor == nil { anchor = substitutionAnchor(mask, width, height) }   // new run
        lastTime = time
        guard let a = anchor else { return }
        let age = Double(max(0.04, time))
        guard age < duration else { drawLog(ctx, landed(a, H), opacity: 1, scale: 1); return }
        smoke(ctx, a, age, foreground: false)
        drawLog(ctx, falling(a, H, age), opacity: min(1, max(0, (age - 0.05) / 0.15)), scale: 1.15 - min(age, 0.25) * 0.6)
        smoke(ctx, a, age, foreground: true)
    }

    /// Log at the person's torso. ponytail: bbox of all mask pixels, not the largest component.
    func substitutionAnchor(_ mask: CVPixelBuffer?, _ width: Int, _ height: Int) -> (cx: Double, cy: Double, size: Double) {
        let W = Double(width), H = Double(height)
        guard let b = MaskTools.box(mask, threshold: 115) else { return (W / 2, H / 2, H * 0.57) }
        let x = b.minX * W, y = b.minY * H, w = b.width * W, h = b.height * H
        let size = min(max(h * 0.58, H * 0.24), H * 0.70)
        return (min(max(x + w * 0.5, size / 3), W - size / 3), min(max(y + h * 0.52, size / 3), H - size / 3), size)
    }

    private func landed(_ a: (cx: Double, cy: Double, size: Double), _ H: Double) -> (cx: Double, cy: Double, size: Double) {
        (a.cx, max(a.cy, H - (a.size * 0.48).rounded()), a.size)
    }

    /// Accelerates down, touches the frame floor, settles with a small bounce.
    private func falling(_ a: (cx: Double, cy: Double, size: Double), _ H: Double, _ age: Double) -> (cx: Double, cy: Double, size: Double) {
        let floorY = landed(a, H).cy, distance = floorY - a.cy
        if distance <= 0 || age <= 0.18 { return a }
        let elapsed = age - 0.18, gravity = H * 3.2
        let fall = gravity * elapsed * elapsed * 0.5
        if fall < distance { return (a.cx, a.cy + fall, a.size) }
        let bounceAge = elapsed - (2 * distance / gravity).squareRoot()
        let bounce = a.size * 0.075 * exp(-5 * bounceAge) * abs(sin(11 * bounceAge))
        return (a.cx, floorY - bounce, a.size)
    }

    private func drawLog(_ ctx: CGContext, _ a: (cx: Double, cy: Double, size: Double), opacity: Double, scale: Double) {
        guard opacity > 0, let sprite else { return }
        let h = max(1, a.size * scale), w = h * Double(sprite.width) / Double(sprite.height)
        ctx.saveGState()
        ctx.setAlpha(opacity)
        ctx.translateBy(x: a.cx - w / 2, y: a.cy + h / 2)   // y-down context: flip back for the image
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .medium
        ctx.draw(sprite, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    private func smoke(_ ctx: CGContext, _ a: (cx: Double, cy: Double, size: Double), _ age: Double, foreground: Bool) {
        let (cx, cy, size) = a
        var rng = SeededRNG(foreground ? 9127 : 1934)
        let reveal = min(1, age / 0.16)
        let fade = max(0, 1 - max(0, age - 0.33) / 1.12)
        guard fade > 0 else { return }
        let margin = size * 1.35
        ctx.saveGState()
        ctx.clip(to: CGRect(x: cx - margin, y: cy - margin, width: margin * 2, height: margin * 2))
        // cv2 overwrote pixels in an RGBA layer, then blended it with its alpha: same as drawing
        // opaque shapes in a transparency layer blended at (layer alpha * reveal * fade).
        ctx.setAlpha((foreground ? 190.0 : 125.0) / 255 * reveal * fade)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(foreground ? rgb(235, 235, 229) : rgb(166, 162, 152))
        let radius = size * (0.27 + 0.54 * min(age, 1))
        for _ in 0..<(foreground ? 22 : 18) {
            let angle = rng.uniform(0, 2 * .pi)
            let distance = radius * rng.uniform(0.25, 1)
            let x = cx + cos(angle) * distance
            let y = cy + sin(angle) * distance * 0.63 - age * size * 0.13
            let puff = max(2, size * rng.uniform(0.09, 0.20) * (0.7 + age * 0.7))
            let rot = rng.uniform(-25, 25) * .pi / 180
            let t = CGAffineTransform(translationX: x, y: y).rotated(by: rot)
            ctx.addPath(CGPath(ellipseIn: CGRect(x: -puff, y: -puff * 0.68, width: puff * 2, height: puff * 1.36), transform: [t]))
        }
        ctx.fillPath()
        // long white winding ribbons
        ctx.setStrokeColor(rgb(245, 247, 244))
        ctx.setLineWidth(max(2, size * 0.025))
        ctx.setLineCap(.round)
        for d in [-1.0, 1.0] {
            let c = CGPoint(x: cx + d * size * 0.13, y: cy - size * 0.13 - age * size * 0.09)
            let ax = max(2, size * (0.30 + age * 0.27)), ay = max(2, size * (0.09 + age * 0.12))
            let path = CGMutablePath()
            for i in 0...40 {   // ellipse arc 20°..230°, rotated d*15°
                let th = (20 + 210 * Double(i) / 40) * .pi / 180, r = d * 15 * .pi / 180
                let px = ax * cos(th), py = ay * sin(th)
                let p = CGPoint(x: c.x + px * cos(r) - py * sin(r), y: c.y + px * sin(r) + py * cos(r))
                i == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            ctx.addPath(path)
        }
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

// MARK: - Teleport (speed lines + flash)

public final class TeleportEffect: Effect {
    public let kind: EffectKind = .teleport
    public let duration: Double = 0.95          // TELEPORT_SECONDS
    public var returnDuration: Double { duration }
    public var exposure = SIMD3<Float>(1, 1, 1)
    public var hasOverlay: Bool { true }
    static let vanishPoint = 0.5

    private let blend: BlendPass
    private var lines: [(x: Double, phase: Double, speed: Double, length: Double, thickness: Double)] = []
    private var lastTime: Float = .infinity

    public init(pipelines: PipelineCache) throws { blend = try BlendPass(pipelines: pipelines) }

    private func progress(_ time: Float, _ reverse: Bool) -> Double {
        let p = min(max(Double(time) / duration, 0), 1)
        return reverse ? 1 - p : p
    }

    private static func bump(_ v: Double, _ start: Double, _ peak: Double, _ end: Double) -> Double {
        if v <= start || v >= end { return 0 }
        return v < peak ? (v - start) / (peak - start) : (end - v) / (end - peak)
    }

    public func encode(into cb: MTLCommandBuffer, frame: MTLTexture, plate: MTLTexture, mask: MTLTexture,
                       progress _: Float, time: Float, reverse: Bool, output: MTLTexture) {
        let p = progress(time, reverse)
        let fade = min(max((p - (Self.vanishPoint - 0.2)) / 0.2, 0), 1)
        let flash = Self.bump(p, Self.vanishPoint - 0.12, Self.vanishPoint - 0.02, Self.vanishPoint + 0.08)
        blend.encode(cb, frame: frame, plate: plate, mask: mask, output: output,
                     personAlpha: Float(1 - fade), flash: Float(flash), exposure: exposure)
    }

    public func encodeSteady(into cb: MTLCommandBuffer, frame: MTLTexture, plate: MTLTexture, time: Float, output: MTLTexture) {
        blend.encode(cb, frame: plate, plate: plate, mask: plate, output: output, personAlpha: 0, flash: 0, exposure: exposure)
    }

    public func drawOverlay(in ctx: CGContext, width: Int, height: Int, mask: CVPixelBuffer?,
                            time: Float, reverse: Bool, steady: Bool) {
        guard !steady else { return }
        let W = Double(width), H = Double(height), s = H / 720
        if time < lastTime { lines = makeLines(mask, W, s, seed: UInt64(Date().timeIntervalSince1970 * 1000)) }   // new run
        lastTime = time
        let p = progress(time, reverse), age = Double(time)
        let intensity = min(p / 0.18, 1) * (1 - min(max((p - 0.6) / 0.4, 0), 1))
        guard !lines.isEmpty, intensity > 0.01, let box = MaskTools.box(mask, threshold: 77),
              let clip = MaskTools.image(mask) else { return }
        let y = box.minY * H, h = box.height * H, span = h * 1.3

        ctx.saveGState()
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H))   // un-flip so the mask image is upright
        // ponytail: clip to the mask itself; original dilated it 25 px sideways + blur 6 px. Widen if lines look cut.
        ctx.clip(to: CGRect(x: 0, y: 0, width: W, height: H), mask: clip)
        ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H))
        ctx.setAlpha(intensity)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // halo: BGR (255,220,120) glow at 0.7, then white core (cv2 GaussianBlur sigma 5 * 1.6)
        ctx.setShadow(offset: .zero, blur: 16 * s, color: CGColor(srgbRed: 120 / 255, green: 220 / 255, blue: 1, alpha: 0.95))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineCap(.butt)
        for l in lines {
            let offset = (l.phase + age * l.speed).truncatingRemainder(dividingBy: 1)
            let center = y + h + 0.15 * h - offset * span, half = l.length * h / 2
            ctx.setLineWidth(l.thickness * s)
            ctx.move(to: CGPoint(x: l.x, y: center - half)); ctx.addLine(to: CGPoint(x: l.x, y: center + half))
            ctx.strokePath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// Vertical lines (x, phase, speed, length, thickness) across the silhouette's width.
    func makeLines(_ mask: CVPixelBuffer?, _ W: Double, _ s: Double, seed: UInt64)
        -> [(x: Double, phase: Double, speed: Double, length: Double, thickness: Double)] {
        guard let b = MaskTools.box(mask, threshold: 77) else { return [] }
        let x = b.minX * W, w = b.width * W
        var rng = SeededRNG(seed)
        let thick: [Double] = [1, 2, 2, 3, 4]
        return (0..<max(14, Int(w / (9 * s)))).map { _ in
            (rng.uniform(x - 10 * s, x + w + 10 * s), rng.next(), rng.uniform(1.6, 3.2), rng.uniform(0.25, 0.7),
             thick[min(4, Int(rng.next() * 5))])
        }
    }
}
