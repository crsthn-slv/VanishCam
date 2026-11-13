import XCTest
import CoreVideo
@testable import VanishCore

final class UYVYConverterTests: XCTestCase {
    func testRedConvertsToNonZeroUYVY() throws {
        let src = try XCTUnwrap(PixelBufferIO.make(width: 64, height: 32))
        PixelBufferIO.fill(src, r: 255, g: 0, b: 0)
        let out = try XCTUnwrap(try UYVYConverter().convert(src))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(out), kCVPixelFormatType_422YpCbCr8)
        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        let off = 16 * CVPixelBufferGetBytesPerRow(out) + 32   // middle of the image: Cb Y Cr Y
        print("UYVY bytes:", p[off], p[off + 1], p[off + 2], p[off + 3])
        // red in video-range BT.601: Y ~81, Cb ~90, Cr ~240
        XCTAssertEqual(Int(p[off + 1]), 82, accuracy: 4)
        XCTAssertEqual(Int(p[off]), 90, accuracy: 4)
        XCTAssertEqual(Int(p[off + 2]), 240, accuracy: 4)
    }
}
