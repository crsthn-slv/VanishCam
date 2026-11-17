import XCTest
import CoreVideo
import Metal
@testable import VanishCore

final class PersonFractionTests: XCTestCase {
    func testEmptyAndFullMask() throws {
        let m = try XCTUnwrap(PixelBufferIO.make(width: 32, height: 16, format: kCVPixelFormatType_OneComponent8))
        CVPixelBufferLockBaseAddress(m, [])
        memset(CVPixelBufferGetBaseAddress(m), 0, CVPixelBufferGetDataSize(m))
        CVPixelBufferUnlockBaseAddress(m, [])
        XCTAssertEqual(VanishPipeline.personFraction(m), 0, accuracy: 1e-6)
        CVPixelBufferLockBaseAddress(m, [])
        memset(CVPixelBufferGetBaseAddress(m), 200, CVPixelBufferGetDataSize(m))
        CVPixelBufferUnlockBaseAddress(m, [])
        XCTAssertEqual(VanishPipeline.personFraction(m), 1.0, accuracy: 1e-6)
        XCTAssertEqual(VanishPipeline.personFraction(nil), 0)
    }
}

final class ExposureGainTests: XCTestCase {
    func testGainMatchesBrightness() throws {
        // live frame twice as bright as the plate, empty mask -> per-channel gain ~2
        let f = try XCTUnwrap(PixelBufferIO.make(width: 64, height: 48))
        let p = try XCTUnwrap(PixelBufferIO.make(width: 64, height: 48))
        PixelBufferIO.fill(f, r: 200, g: 200, b: 200)
        PixelBufferIO.fill(p, r: 100, g: 100, b: 100)
        let g = VanishPipeline.exposureGain(frame: f, plate: p, mask: nil)
        for i in 0..<3 { XCTAssertEqual(g[i], 2.0, accuracy: 0.2) }
    }

    /// A gesture made while the vanish animation still runs is kept, not swallowed: it brings you back once gone.
    func testGestureDuringAnimationFiresWhenGone() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        final class Scripted: GestureDetecting, PersonSegmenting {
            private let lock = NSLock(); private var g = Gesture.none
            func set(_ x: Gesture) { lock.lock(); g = x; lock.unlock() }
            func detect(in pixelBuffer: CVPixelBuffer) -> Gesture { lock.lock(); defer { lock.unlock() }; return g }
            func mask(for pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? { nil }
        }
        let fake = Scripted()
        var s = VanishPipeline.Settings(plateURL: URL(fileURLWithPath: "/nonexistent/plate.png"))
        s.outputWidth = 320; s.outputHeight = 180; s.liveBackground = true; s.effect = .substitution
        let p = try VanishPipeline(settings: s, renderer: EffectRenderer(), detector: fake, segmenter: fake)
        let frame = try XCTUnwrap(PixelBufferIO.make(width: 320, height: 180))
        func run(_ t: Double) { let end = Date() + t; while Date() < end { _ = p.process(frame); Thread.sleep(forTimeInterval: 0.02) } }
        fake.set(.handSeal); run(0.3)                 // seal fires at once
        XCTAssertEqual(p.phaseName, "vanishing")
        fake.set(.none); run(0.6)                     // > 0.4 s without: re-armed, animation (1.45 s) still running
        XCTAssertEqual(p.phaseName, "vanishing")
        fake.set(.handSeal); run(1.0)                 // seal again mid-animation -> fires when gone (old bug: stuck gone)
        XCTAssertTrue(["returning", "live"].contains(p.phaseName), p.phaseName)
    }
}
