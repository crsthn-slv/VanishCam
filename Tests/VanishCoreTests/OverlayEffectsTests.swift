import CoreVideo
import Metal
import XCTest
@testable import VanishCore

final class OverlayEffectsTests: XCTestCase {
    let W = 640, H = 360
    static let previewDir = URL(fileURLWithPath: "/tmp/vanishcam-effect-preview")

    private func renderer() throws -> EffectRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        return try EffectRenderer()
    }
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> CVPixelBuffer {
        let pb = PixelBufferIO.make(width: W, height: H)!; PixelBufferIO.fill(pb, r: r, g: g, b: b); return pb
    }
    /// person = left-centre block (x 20%-45%, y 20%-95%) so the centroid is not at 0.5
    private func personMask() -> CVPixelBuffer {
        let mw = 160, mh = 90
        let pb = PixelBufferIO.make(width: mw, height: mh, format: kCVPixelFormatType_OneComponent8)!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<mh { for x in 0..<mw {
            base[y * bpr + x] = (x >= mw * 20 / 100 && x < mw * 45 / 100 && y >= mh * 20 / 100 && y < mh * 95 / 100) ? 255 : 0
        } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
    /// mean absolute BGR difference between two buffers over the whole image
    private func meanDiff(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
        let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let ra = CVPixelBufferGetBytesPerRow(a), rb = CVPixelBufferGetBytesPerRow(b)
        var sum = 0.0
        for y in 0..<H { for x in 0..<W { for c in 0..<3 {
            sum += abs(Double(pa[y * ra + x * 4 + c]) - Double(pb[y * rb + x * 4 + c]))
        } } }
        return sum / Double(W * H * 3)
    }

    /// GPU pass + CPU overlay, like the pipeline does.
    private func frameAt(_ r: EffectRenderer, _ e: Effect, _ frame: CVPixelBuffer, _ plate: CVPixelBuffer,
                         _ mask: CVPixelBuffer, time: Float, steady: Bool = false) throws -> CVPixelBuffer {
        let out = PixelBufferIO.make(width: W, height: H)!
        if steady { XCTAssertTrue(r.renderSteady(effect: e, frame: frame, plate: plate, time: time, into: out)) }
        else { XCTAssertTrue(r.render(effect: e, frame: frame, plate: plate, mask: mask, progress: time / Float(e.duration),
                                      time: time, reverse: false, into: out)) }
        try PixelBufferIO.withContext(out) { ctx in
            ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
            e.drawOverlay(in: ctx, width: W, height: H, mask: steady ? nil : mask, time: time, reverse: false, steady: steady)
        }
        return out
    }

    func testSubstitution() throws {
        let r = try renderer(), e = try XCTUnwrap(try r.effect(.substitution))
        let frame = solid(200, 120, 40), plate = solid(30, 90, 200), mask = personMask()
        try? FileManager.default.createDirectory(at: Self.previewDir, withIntermediateDirectories: true)
        var outs: [Float: CVPixelBuffer] = [:]
        for t: Float in [0.04, 0.3, 0.8, 1.5] {
            outs[t] = try frameAt(r, e, frame, plate, mask, time: t)
            try PixelBufferIO.writePNG(outs[t]!, to: Self.previewDir.appendingPathComponent("substitution-t\(t).png"))
        }
        XCTAssertGreaterThan(meanDiff(outs[0.3]!, plate), 3, "smoke + log over the plate")
        let steady = try frameAt(r, e, frame, plate, mask, time: 0.1, steady: true)
        try PixelBufferIO.writePNG(steady, to: Self.previewDir.appendingPathComponent("substitution-steady.png"))
        if Assets.url("log.png") != nil { XCTAssertGreaterThan(meanDiff(steady, plate), 1, "landed log on the plate") }   // sprite not in repo
        XCTAssertLessThan(e.returnDuration, 0.01, "original: instant reappear")
    }

    func testTeleport() throws {
        let r = try renderer(), e = try XCTUnwrap(try r.effect(.teleport))
        let frame = solid(200, 120, 40), plate = solid(30, 90, 200), mask = personMask()
        try? FileManager.default.createDirectory(at: Self.previewDir, withIntermediateDirectories: true)
        var outs: [Float: CVPixelBuffer] = [:]
        for t: Float in [0, 0.2, 0.45, 0.95] {
            outs[t] = try frameAt(r, e, frame, plate, mask, time: t)
            try PixelBufferIO.writePNG(outs[t]!, to: Self.previewDir.appendingPathComponent("teleport-t\(t).png"))
        }
        let o = outs[0]!   // start: live person (outside the mask the blend shows the plate, as in the original)
        CVPixelBufferLockBaseAddress(o, .readOnly)
        let red = CVPixelBufferGetBaseAddress(o)!.assumingMemoryBound(to: UInt8.self)[(H / 2) * CVPixelBufferGetBytesPerRow(o) + (W / 3) * 4 + 2]
        CVPixelBufferUnlockBaseAddress(o, .readOnly)
        XCTAssertEqual(Int(red), 200, accuracy: 3, "start = live person")
        XCTAssertLessThan(meanDiff(outs[0.95]!, plate), 2, "end = plate")
        XCTAssertGreaterThan(meanDiff(outs[0.2]!, frame), 0.5, "speed lines drawn")
    }

    func testMaskBox() throws {
        let b = try XCTUnwrap(MaskTools.box(personMask(), threshold: 115))
        XCTAssertEqual(b.minX, 0.2, accuracy: 0.02); XCTAssertEqual(b.maxX, 0.45, accuracy: 0.02)
        XCTAssertEqual(b.minY, 0.2, accuracy: 0.02); XCTAssertEqual(b.maxY, 0.95, accuracy: 0.02)
        XCTAssertNil(MaskTools.box(nil, threshold: 0))
    }

    /// Hole under the person is filled from the visible background (vertical gradient survives).
    func testFillBackground() throws {
        let frame = PixelBufferIO.make(width: W, height: H)!
        CVPixelBufferLockBaseAddress(frame, [])
        let fb = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self), fr = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<H { for x in 0..<W { let o = y * fr + x * 4   // blue->white gradient top to bottom
            fb[o] = 255; fb[o + 1] = UInt8(150 + 100 * y / H); fb[o + 2] = UInt8(100 + 150 * y / H); fb[o + 3] = 255 } }
        CVPixelBufferUnlockBaseAddress(frame, [])
        let out = PixelBufferIO.make(width: 64, height: 36)!
        VanishPipeline.fillBackground(frame: frame, mask: personMask(), into: out)
        CVPixelBufferLockBaseAddress(out, .readOnly); defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let ob = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self), orr = CVPixelBufferGetBytesPerRow(out)
        let inside = Int(ob[18 * orr + 20 * 4 + 2])          // cell (20,18): under the person, red ≈ 100+150*0.5
        XCTAssertEqual(inside, 175, accuracy: 25)
    }

    /// Memory keeps the visible background; under the person it uses the fill until seen.
    func testBackgroundMemory() throws {
        let r = try renderer()
        let frame = solid(200, 120, 40), fill = solid(10, 250, 10), prev = PixelBufferIO.make(width: W, height: H)!
        PixelBufferIO.fill(prev, r: 0, g: 0, b: 0, a: 0)
        let mem = PixelBufferIO.make(width: W, height: H)!, clean = PixelBufferIO.make(width: W, height: H)!
        XCTAssertTrue(r.backgroundMemory(frame: frame, previous: prev, mask: personMask(), fill: fill, memory: mem, clean: clean))
        func px(_ pb: CVPixelBuffer, _ x: Int, _ y: Int) -> (r: Int, a: Int) {
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), o = y * CVPixelBufferGetBytesPerRow(pb) + x * 4
            return (Int(b[o + 2]), Int(b[o + 3]))
        }
        XCTAssertEqual(px(mem, W * 9 / 10, H / 2).r, 200, accuracy: 2)   // visible: frame
        XCTAssertEqual(px(mem, W / 3, H / 2).r, 10, accuracy: 2)         // hidden, never seen: fill
        XCTAssertEqual(px(clean, W / 3, H / 2).r, 200, accuracy: 2)      // person core kept in clean frame
        // gone (imageWeight 1): whole frame is the background, no camera pixels left
        XCTAssertTrue(r.backgroundMemory(frame: frame, previous: prev, mask: personMask(), fill: fill, memory: mem, clean: clean, imageWeight: 1))
        XCTAssertEqual(px(mem, W * 9 / 10, H / 2).r, 10, accuracy: 2)
        XCTAssertEqual(px(mem, W / 3, H / 2).r, 10, accuracy: 2)
    }

    /// loadImage must leave alpha = 255 (vc_bgmem treats alpha 0 as "no image": falls back to fill).
    func testLoadedImageIsOpaque() throws {
        let src = PixelBufferIO.make(width: 32, height: 18)!   // fully transparent PNG
        PixelBufferIO.fill(src, r: 0, g: 0, b: 0, a: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vc-transparent.png")
        try PixelBufferIO.writePNG(src, to: url, alpha: true)
        for mirrored in [false, true] {
            let pb = try PixelBufferIO.loadImage(at: url, width: 64, height: 36, mirrored: mirrored)
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let b = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), r = CVPixelBufferGetBytesPerRow(pb)
            for y in [0, 18, 35] { for x in [0, 32, 63] { XCTAssertEqual(b[y * r + x * 4 + 3], 255) } }
        }
    }

    /// Alignment recovers mirror / scale / offset of a textured image placed like macOS might.
    func testBackgroundAlignRecoversPlacement() throws {
        let tex = PixelBufferIO.make(width: 320, height: 180)!
        CVPixelBufferLockBaseAddress(tex, [])
        let b = CVPixelBufferGetBaseAddress(tex)!.assumingMemoryBound(to: UInt8.self), r = CVPixelBufferGetBytesPerRow(tex)
        var seed: UInt64 = 7
        for y in 0..<180 { for x in 0..<320 {   // blocky random texture + horizontal ramp (breaks mirror symmetry)
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8((Int((x / 10 * 37 + y / 10 * 91) % 97) * 2 + x / 3) % 256)
            let o = y * r + x * 4; b[o] = v; b[o + 1] = v; b[o + 2] = v; b[o + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(tex, [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("align-\(UUID().uuidString).png")
        try PixelBufferIO.writePNG(tex, to: url)
        let image = try PixelBufferIO.loadImage(at: url, width: W, height: H)
        let frame = try PixelBufferIO.loadImage(at: url, width: W, height: H, mirrored: true, scale: 1.2, offset: CGPoint(x: 0.05, y: -0.03))
        let fit = BackgroundAlign.fit(frame: frame, image: image, mask: personMask())
        XCTAssertTrue(fit.mirrored)
        XCTAssertEqual(fit.scale, 1.2, accuracy: 0.02)
        XCTAssertEqual(fit.dx, 0.05, accuracy: 0.01)
        XCTAssertEqual(fit.dy, -0.03, accuracy: 0.01)
        // and re-rendering with the fit reproduces the frame
        let redo = try PixelBufferIO.loadImage(at: url, width: W, height: H, mirrored: fit.mirrored, scale: fit.scale, offset: CGPoint(x: fit.dx, y: fit.dy))
        XCTAssertLessThan(meanDiff(redo, frame), 8)
    }

}
