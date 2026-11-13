import XCTest
import CoreVideo
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
}
