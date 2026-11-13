import Accelerate
import CoreVideo
import Foundation

/// Builds the empty-room plate by averaging N BGRA frames (float accumulation with vDSP), and
/// saves / loads plates as PNG (including arbitrary images aspect-filled to the camera size).
public final class BackgroundPlate {
    public let targetFrames: Int
    public private(set) var frameCount = 0
    /// The finished plate (nil until `targetFrames` frames have been added, or one was loaded/set).
    public private(set) var pixelBuffer: CVPixelBuffer?

    private var sum: [Float] = []
    private var width = 0, height = 0

    public init(targetFrames: Int = 18) { self.targetFrames = max(1, targetFrames) }

    public var isComplete: Bool { pixelBuffer != nil }
    public var progress: Double { isComplete ? 1 : Double(frameCount) / Double(targetFrames) }

    /// Discards the plate and any partial accumulation.
    public func reset() {
        sum = []; frameCount = 0; width = 0; height = 0; pixelBuffer = nil
    }

    /// Adds a BGRA frame. Returns true when this frame completed the plate.
    /// A size change restarts accumulation. Frames added after completion are ignored (call `reset`).
    @discardableResult
    public func add(_ frame: CVPixelBuffer) -> Bool {
        guard !isComplete, CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return false }
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        if w != width || h != height || sum.isEmpty {
            width = w; height = h; frameCount = 0
            sum = [Float](repeating: 0, count: w * h * 4)
        }
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(frame)
        let rowLen = w * 4
        var tmp = [Float](repeating: 0, count: rowLen)
        sum.withUnsafeMutableBufferPointer { acc in
            for y in 0..<h {
                vDSP_vfltu8(base + y * bpr, 1, &tmp, 1, vDSP_Length(rowLen))
                let row = acc.baseAddress! + y * rowLen
                vDSP_vadd(row, 1, tmp, 1, row, 1, vDSP_Length(rowLen))
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, .readOnly)
        frameCount += 1
        guard frameCount >= targetFrames else { return false }
        pixelBuffer = finish()
        sum = []
        return pixelBuffer != nil
    }

    private func finish() -> CVPixelBuffer? {
        guard let out = PixelBufferIO.make(width: width, height: height) else { return nil }
        let n = vDSP_Length(sum.count)
        var scale = 1 / Float(frameCount), half: Float = 0.5
        vDSP_vsmsa(sum, 1, &scale, &half, &sum, 1, n)   // mean + 0.5 for rounding
        var lo: Float = 0, hi: Float = 255
        vDSP_vclip(sum, 1, &lo, &hi, &sum, 1, n)
        CVPixelBufferLockBaseAddress(out, [])
        let base = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(out)
        let rowLen = width * 4
        sum.withUnsafeBufferPointer { acc in
            for y in 0..<height {
                vDSP_vfixu8(acc.baseAddress! + y * rowLen, 1, base + y * bpr, 1, vDSP_Length(rowLen))
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }

    /// Uses an existing buffer as the plate (e.g. a single captured frame).
    public func set(_ plate: CVPixelBuffer) {
        reset()
        pixelBuffer = plate
    }

    public func save(to url: URL) throws {
        guard let pixelBuffer else { throw EffectError.io("no plate to save") }
        try PixelBufferIO.writePNG(pixelBuffer, to: url)
    }

    /// Loads a saved plate or any image file, scaled/cropped to fill width x height.
    public func load(from url: URL, width: Int, height: Int) throws {
        set(try PixelBufferIO.loadImage(at: url, width: width, height: height))
    }
}
