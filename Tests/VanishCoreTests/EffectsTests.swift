import CoreVideo
import Metal
import XCTest
@testable import VanishCore

final class EffectsTests: XCTestCase {
    static let previewDir = URL(fileURLWithPath: "/tmp/vanishcam-effect-preview")
    let W = 1280, H = 720

    private func makeRenderer() throws -> EffectRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        return try EffectRenderer()
    }

    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int? = nil, h: Int? = nil) -> CVPixelBuffer {
        let pb = PixelBufferIO.make(width: w ?? W, height: h ?? H)!
        PixelBufferIO.fill(pb, r: r, g: g, b: b)
        return pb
    }

    /// 8-bit mask at a different (quarter) resolution: left half = 255.
    private func leftHalfMask() -> CVPixelBuffer {
        let mw = 320, mh = 180
        let pb = PixelBufferIO.make(width: mw, height: mh, format: kCVPixelFormatType_OneComponent8)!
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<mh { for x in 0..<mw { base[y * bpr + x] = x < mw / 2 ? 255 : 0 } }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// Mean RGB (0-255) over a pixel rectangle, plus the fraction of pixels that are "plate-like" (blue > red).
    private func stats(_ pb: CVPixelBuffer, x: Range<Int>, y: Range<Int>) -> (r: Double, g: Double, b: Double, plateFrac: Double) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var r = 0.0, g = 0.0, b = 0.0, plate = 0.0
        for yy in y { for xx in x {
            let p = base + yy * bpr + xx * 4
            b += Double(p[0]); g += Double(p[1]); r += Double(p[2])
            if p[0] > p[2] { plate += 1 }
        } }
        let n = Double(x.count * y.count)
        return (r / n, g / n, b / n, plate / n)
    }

    func testDissolveProgressRendersExpectedPixels() throws {
        let renderer = try makeRenderer()
        let effect = try XCTUnwrap(try renderer.effect(.dissolve))
        XCTAssertEqual(effect.kind, .dissolve)
        XCTAssertEqual(effect.duration, 1.6, accuracy: 1e-9)

        let frame = solid(255, 0, 0), plate = solid(0, 0, 255), mask = leftHalfMask()
        let inMask = 0..<Int(Double(W) * 0.45), outMask = Int(Double(W) * 0.55)..<W, all = 0..<H
        var paths: [String] = []

        for progress: Float in [0, 0.5, 1] {
            let out = PixelBufferIO.make(width: W, height: H)!
            XCTAssertTrue(renderer.render(effect: effect, frame: frame, plate: plate, mask: mask,
                                          progress: progress, time: 1.234, reverse: false, into: out))
            let url = Self.previewDir.appendingPathComponent(String(format: "dissolve-p%.1f.png", progress))
            try PixelBufferIO.writePNG(out, to: url)
            paths.append(url.path)

            let outside = stats(out, x: outMask, y: all)
            if progress < 0.8 {   // last 20%: the whole frame converges to the plate (no outline at the end)
                XCTAssertGreaterThan(outside.r, 254, "outside mask must stay frame (p=\(progress))")
                XCTAssertLessThan(outside.b, 1, "outside mask must stay frame (p=\(progress))")
            } else if progress == 1 { XCTAssertGreaterThan(outside.b, 254, "end = plate everywhere") }

            let inside = stats(out, x: inMask, y: all)
            switch progress {
            case 0:
                XCTAssertGreaterThan(inside.r, 254); XCTAssertLessThan(inside.b, 1)
            case 1:
                XCTAssertGreaterThan(inside.b, 254); XCTAssertLessThan(inside.r, 1)
            default:
                // Mid-way: bottom mostly gone, top mostly still there, overall a real mix.
                XCTAssert((0.25...0.75).contains(inside.plateFrac), "plateFrac \(inside.plateFrac)")
                let top = stats(out, x: inMask, y: 0..<H / 6), bottom = stats(out, x: inMask, y: H * 5 / 6..<H)
                XCTAssertLessThan(top.plateFrac, 0.1)
                XCTAssertGreaterThan(bottom.plateFrac, 0.9)
                XCTAssertGreaterThan(inside.g, 1.5, "blue glow on the burn front")
            }
        }
        print("Dissolve previews:\n" + paths.joined(separator: "\n"))
    }

    func testReverseAndPassThrough() throws {
        let renderer = try makeRenderer()
        let effect = try XCTUnwrap(try renderer.effect(.dissolve))
        let frame = solid(255, 0, 0), plate = solid(0, 0, 255), mask = leftHalfMask()
        let out = PixelBufferIO.make(width: W, height: H)!

        renderer.render(effect: effect, frame: frame, plate: plate, mask: mask,
                        progress: 0, time: 0, reverse: true, into: out)
        XCTAssertGreaterThan(stats(out, x: 0..<500, y: 0..<H).b, 254, "reverse start = person gone")
        renderer.render(effect: effect, frame: frame, plate: plate, mask: mask,
                        progress: 1, time: 0, reverse: true, into: out)
        XCTAssertGreaterThan(stats(out, x: 0..<500, y: 0..<H).r, 254, "reverse end = person back")

        // Pass-through: blit path (same size) and resample path (different size).
        let green = solid(0, 255, 0)
        XCTAssertTrue(renderer.render(effect: nil, frame: green, plate: nil, mask: nil,
                                      progress: 0, time: 0, reverse: false, into: out))
        XCTAssertGreaterThan(stats(out, x: 0..<W, y: 0..<H).g, 254)
        let small = PixelBufferIO.make(width: 640, height: 360)!
        XCTAssertTrue(renderer.passThrough(frame: frame, into: small))
        XCTAssertGreaterThan(stats(small, x: 0..<640, y: 0..<360).r, 254)
    }

    func testDissolvePerformance720p() throws {
        let renderer = try makeRenderer()
        let effect = try XCTUnwrap(try renderer.effect(.dissolve))
        let frame = solid(200, 120, 90), plate = solid(30, 60, 90), mask = leftHalfMask()
        let out = PixelBufferIO.make(width: W, height: H)!
        renderer.render(effect: effect, frame: frame, plate: plate, mask: mask, progress: 0.5, time: 0, reverse: false, into: out)

        let n = 120
        var encodeTotal = 0.0
        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<n {
            let e0 = CFAbsoluteTimeGetCurrent()
            let sem = DispatchSemaphore(value: 0)
            renderer.render(effect: effect, frame: frame, plate: plate, mask: mask,
                            progress: Float(i) / Float(n), time: Float(i) / 30, reverse: false, into: out,
                            waitUntilCompleted: false) { sem.signal() }
            encodeTotal += CFAbsoluteTimeGetCurrent() - e0
            sem.wait()
        }
        let wall = (CFAbsoluteTimeGetCurrent() - t0) / Double(n) * 1000
        let cpu = encodeTotal / Double(n) * 1000
        print(String(format: "Dissolve 1280x720: %.3f ms/frame round-trip (CPU encode+submit %.3f ms)", wall, cpu))
        XCTAssertLessThan(wall, 16, "should comfortably fit a 60 fps budget")

        let p0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<n { renderer.passThrough(frame: frame, into: out) }
        print(String(format: "Pass-through 1280x720: %.3f ms/frame round-trip",
                     (CFAbsoluteTimeGetCurrent() - p0) / Double(n) * 1000))
    }

    func testBackgroundPlateAveragingAndPNG() throws {
        let plate = BackgroundPlate(targetFrames: 18)
        let a = solid(10, 100, 200, w: 64, h: 48), b = solid(20, 110, 211, w: 64, h: 48)
        for i in 0..<17 { XCTAssertFalse(plate.add(i.isMultiple(of: 2) ? a : b)) }
        XCTAssertTrue(plate.add(b))
        let pb = try XCTUnwrap(plate.pixelBuffer)
        let s = stats(pb, x: 0..<64, y: 0..<48)
        XCTAssertEqual(s.r, 15, accuracy: 0.6); XCTAssertEqual(s.g, 105, accuracy: 0.6); XCTAssertEqual(s.b, 205.5, accuracy: 0.6)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vanishcam-plate-test.png")
        try plate.save(to: url)
        let loaded = BackgroundPlate()
        try loaded.load(from: url, width: 64, height: 48)
        let l = stats(try XCTUnwrap(loaded.pixelBuffer), x: 0..<64, y: 0..<48)
        XCTAssertEqual(l.r, s.r, accuracy: 1); XCTAssertEqual(l.b, s.b, accuracy: 1)

        // Aspect fill: 200x100 image (left red, right blue) into 100x100 -> centre crop keeps both halves.
        let wide = solid(255, 0, 0, w: 200, h: 100)
        CVPixelBufferLockBaseAddress(wide, [])
        let base = CVPixelBufferGetBaseAddress(wide)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<100 { for x in 100..<200 {
            let p = base + y * CVPixelBufferGetBytesPerRow(wide) + x * 4
            p[0] = 255; p[2] = 0
        } }
        CVPixelBufferUnlockBaseAddress(wide, [])
        let wideURL = FileManager.default.temporaryDirectory.appendingPathComponent("vanishcam-wide-test.png")
        try PixelBufferIO.writePNG(wide, to: wideURL)
        let filled = try PixelBufferIO.loadImage(at: wideURL, width: 100, height: 100)
        XCTAssertGreaterThan(stats(filled, x: 0..<40, y: 0..<100).r, 250)
        XCTAssertGreaterThan(stats(filled, x: 60..<100, y: 0..<100).b, 250)
    }
}
