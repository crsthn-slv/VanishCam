import CoreGraphics
import CoreVideo
import Metal

/// Gesture recognised in the current frame (instantaneous; hold-time logic lives in the state machine).
public enum Gesture: Hashable, Sendable, Codable {
    case none
    case vSign          // index+middle raised (normal vanish)
    case handSeal       // substitution: hands clasped, both index fingers up together
    case foreheadTwoFingers // teleport
}

/// Detects gestures from camera frames. Implementations run Apple Vision; must be cheap (called ~10-12 Hz on a downscaled copy).
public protocol GestureDetecting: AnyObject {
    func detect(in pixelBuffer: CVPixelBuffer) -> Gesture
    /// Debug window support: when on, `detect` also fills `lastDebug` (local UI only, never sent to the output).
    var debugEnabled: Bool { get set }
    var lastDebug: GestureDebugFrame? { get }
}

/// What the detector saw in the last analysed frame (downscaled copy), for the debug window.
public struct GestureDebugFrame: @unchecked Sendable {
    public struct Hand: Sendable {
        /// wrist->mcp->pip->tip polylines (index, middle, ring, little), normalized image coords, y up.
        public var fingers: [[CGPoint]]
        public var readouts: [GestureReadout]
        public var inForehead: Bool
    }
    public var image: CGImage?
    public var hands: [Hand]
    public var sample: [HandSample]
    public var face: FaceSample?
    public var forehead: CGRect?
    public var seal: GestureReadout?
    /// Hands Vision saw but the detector dropped, with the joints below `minJointConfidence`.
    public var dropped: [String] = []
    public var gesture: Gesture
}

/// Person segmentation. Returns a single-channel 8-bit mask (255 = person), same aspect ratio as the input, any size.
public protocol PersonSegmenting: AnyObject {
    func mask(for pixelBuffer: CVPixelBuffer) -> CVPixelBuffer?
}

public enum EffectKind: String, Codable, CaseIterable, Sendable { case dissolve, substitution, teleport }

/// One GPU effect. Pure function of its inputs: reverse = run `progress` backwards (return / reappear).
/// All textures are .bgra8Unorm except `mask` (.r8Unorm). `output` has the same size as `frame`.
public protocol Effect: AnyObject {
    var kind: EffectKind { get }
    /// Total duration in seconds at default speed.
    var duration: Double { get }
    /// Duration of the reappear animation (defaults to `duration`).
    var returnDuration: Double { get }
    /// Per-channel gain applied to the plate so its brightness matches the live frame.
    var exposure: SIMD3<Float> { get set }
    func encode(into commandBuffer: MTLCommandBuffer,
                frame: MTLTexture, plate: MTLTexture, mask: MTLTexture,
                progress: Float, time: Float, reverse: Bool, output: MTLTexture)
    /// Steady state between vanish and return (person absent). Default: copy the plate to the output.
    func encodeSteady(into commandBuffer: MTLCommandBuffer,
                      frame: MTLTexture, plate: MTLTexture, time: Float, output: MTLTexture)
    /// True if `drawOverlay` draws anything (skips the CPU pass otherwise).
    var hasOverlay: Bool { get }
    /// CPU pass after the GPU one (Core Graphics, y-down, origin top-left, pixel units):
    /// sprites, smoke, lines. `steady` = person gone, between vanish and return.
    func drawOverlay(in ctx: CGContext, width: Int, height: Int, mask: CVPixelBuffer?,
                     time: Float, reverse: Bool, steady: Bool)
}

public extension Effect {
    var returnDuration: Double { duration }
    var hasOverlay: Bool { false }
    func drawOverlay(in ctx: CGContext, width: Int, height: Int, mask: CVPixelBuffer?,
                     time: Float, reverse: Bool, steady: Bool) {}
    func encodeSteady(into commandBuffer: MTLCommandBuffer,
                      frame: MTLTexture, plate: MTLTexture, time: Float, output: MTLTexture) {
        EffectSteadyDefault.copyPlate(plate, to: output, in: commandBuffer)
    }
}

/// Pass-through used by the default `encodeSteady` implementation.
private enum EffectSteadyDefault {
    private static var pipelines: [ObjectIdentifier: MTLComputePipelineState] = [:]
    private static let lock = NSLock()

    static func copyPlate(_ src: MTLTexture, to dst: MTLTexture, in cb: MTLCommandBuffer) {
        if src.width == dst.width, src.height == dst.height, src.pixelFormat == dst.pixelFormat,
           let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: src.width, height: src.height, depth: 1),
                      to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
            return
        }
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(dst.device)
        if pipelines[key] == nil { pipelines[key] = try? PipelineCache(device: dst.device).compute("vc_copy", source: "") }
        guard let p = pipelines[key], let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.dispatchPerPixel(p, width: dst.width, height: dst.height)
        enc.endEncoding()
    }
}
