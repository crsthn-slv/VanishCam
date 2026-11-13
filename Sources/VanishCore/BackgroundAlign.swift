import CoreVideo
import Foundation

/// Finds how macOS placed its background image in the camera frame (mirror, scale, offset) by
/// matching the visible background against the aspect-filled image. Coarse grid search at 96x54,
/// refined at 192x108. Brightness-offset invariant (macOS dims/tints the image).
enum BackgroundAlign {
    struct Fit: Equatable { var mirrored = false, scale = 1.0, dx = 0.0, dy = 0.0, cost = Double.infinity }   // dx, dy: fraction of frame, y-down

    /// Grayscale gw x gh samples of a BGRA buffer (2x2 point average per cell). Mirror flips x.
    static func gray(_ pb: CVPixelBuffer, _ gw: Int, _ gh: Int, mirrored: Bool = false) -> [Float] {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), r = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var out = [Float](repeating: 0, count: gw * gh)
        for y in 0..<gh { for x in 0..<gw {
            var acc: Float = 0
            for (ox, oy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                let px = min(Int((Double(x) + ox) * Double(w) / Double(gw)), w - 1), py = min(Int((Double(y) + oy) * Double(h) / Double(gh)), h - 1)
                let o = py * r + px * 4
                acc += 0.11 * Float(b[o]) + 0.59 * Float(b[o + 1]) + 0.30 * Float(b[o + 2])
            }
            out[y * gw + (mirrored ? gw - 1 - x : x)] = acc / 4
        } }
        return out
    }

    /// Visible-background flags (mask < ~3%, dilated by one cell) on the same grid.
    static func visible(_ mask: CVPixelBuffer, _ gw: Int, _ gh: Int) -> [Bool] {
        CVPixelBufferLockBaseAddress(mask, .readOnly); defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let b = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self), r = CVPixelBufferGetBytesPerRow(mask)
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask)
        var person = [Bool](repeating: false, count: gw * gh)
        for y in 0..<gh { for x in 0..<gw { person[y * gw + x] = b[min(y * h / gh, h - 1) * r + min(x * w / gw, w - 1)] > 8 } }
        return (0..<gw * gh).map { i in
            let x = i % gw, y = i / gw
            return !(max(0, y - 1)...min(gh - 1, y + 1)).contains { yy in (max(0, x - 1)...min(gw - 1, x + 1)).contains { person[yy * gw + $0] } }
        }
    }

    /// Mean |F - I - (meanF - meanI)| over visible cells, image sampled through the fit (nearest).
    static func cost(_ f: [Float], _ img: [Float], _ vis: [Bool], _ gw: Int, _ gh: Int, scale s: Double, dx: Double, dy: Double) -> Double {
        func walk(_ body: (Float, Float) -> Void) {
            for y in 0..<gh { for x in 0..<gw where vis[y * gw + x] {
                let u = ((Double(x) + 0.5) / Double(gw) - 0.5 - dx) / s + 0.5, v = ((Double(y) + 0.5) / Double(gh) - 0.5 - dy) / s + 0.5
                guard u >= 0, u < 1, v >= 0, v < 1 else { continue }
                body(f[y * gw + x], img[Int(v * Double(gh)) * gw + Int(u * Double(gw))])
            } }
        }
        var sd: Float = 0, n = 0
        walk { sd += $0 - $1; n += 1 }
        guard n > gw * gh / 8 else { return .infinity }   // too little overlap to judge
        let off = sd / Float(n)
        var acc: Float = 0
        walk { acc += abs($0 - $1 - off) }
        return Double(acc) / Double(n)
    }

    /// Best fit over mirror x scale (0.9...1.6) x offset (±12%). `frame` and `image` same size.
    static func fit(frame: CVPixelBuffer, image: CVPixelBuffer, mask: CVPixelBuffer) -> Fit {
        var best = Fit()
        for mirrored in [false, true] {
            var gw = 96, gh = 54
            var f = gray(frame, gw, gh), img = gray(image, gw, gh, mirrored: mirrored), vis = visible(mask, gw, gh)
            var local = Fit(mirrored: mirrored)
            for s in stride(from: 0.9, through: 1.6, by: 0.02) {
                for ix in -12...12 { for iy in -12...12 {
                    let dx = Double(ix) / 100, dy = Double(iy) / 100
                    let c = cost(f, img, vis, gw, gh, scale: s, dx: dx, dy: dy)
                    if c < local.cost { local = Fit(mirrored: mirrored, scale: s, dx: dx, dy: dy, cost: c) }
                } }
            }
            // refine at 2x resolution around the coarse optimum
            gw = 192; gh = 108
            f = gray(frame, gw, gh); img = gray(image, gw, gh, mirrored: mirrored); vis = visible(mask, gw, gh)
            let c0 = local
            local.cost = cost(f, img, vis, gw, gh, scale: c0.scale, dx: c0.dx, dy: c0.dy)
            for s in stride(from: c0.scale - 0.02, through: c0.scale + 0.02, by: 0.005) {
                for ix in -4...4 { for iy in -4...4 {
                    let dx = c0.dx + Double(ix) * 0.0025, dy = c0.dy + Double(iy) * 0.0025
                    let c = cost(f, img, vis, gw, gh, scale: s, dx: dx, dy: dy)
                    if c < local.cost { local = Fit(mirrored: mirrored, scale: s, dx: dx, dy: dy, cost: c) }
                } }
            }
            if local.cost < best.cost { best = local }
        }
        return best
    }
}
