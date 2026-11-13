import CoreVideo
import Foundation
import Vision

/// Person segmentation via Vision.
/// Returns a OneComponent8 mask (255 = person) at Vision's NATIVE output size. Observed: Vision outputs
/// a fixed 4:3 buffer that covers the whole frame (anisotropically scaled for 16:9 input), so it is NOT
/// aspect-preserving; sampling with normalized (0-1) coordinates + linear filtering in Metal is correct.
/// The returned buffer comes from a pool and is overwritten after the pool recycles it; consume it promptly.
public final class VisionPersonSegmenter: PersonSegmenting {
    private let lock = NSLock()
    private let handler = VNSequenceRequestHandler()
    private let request = VNGeneratePersonSegmentationRequest()
    private var pool: CVPixelBufferPool?
    private var poolSize = (w: 0, h: 0)

    public init(quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) {
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }
    public var quality: VNGeneratePersonSegmentationRequest.QualityLevel {
        get { request.qualityLevel }
        set { lock.lock(); request.qualityLevel = newValue; lock.unlock() }
    }

    public func mask(for pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        do { try handler.perform([request], on: pixelBuffer) } catch { return nil }
        guard let src = request.results?.first?.pixelBuffer else { return nil }
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        if pool == nil || poolSize != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8,
                                          kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                          kCVPixelBufferMetalCompatibilityKey: true,
                                          kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
            var p: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p) == kCVReturnSuccess else { return nil }
            pool = p; poolSize = (w, h)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let dst = out else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let sb = CVPixelBufferGetBaseAddress(src), let db = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let sr = CVPixelBufferGetBytesPerRow(src), dr = CVPixelBufferGetBytesPerRow(dst)
        for y in 0..<h { memcpy(db + y * dr, sb + y * sr, w) }
        return dst
    }
}
