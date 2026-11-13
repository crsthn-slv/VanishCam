import CoreVideo
import Foundation
import Metal

/// Owns the Metal device, queue, texture cache and pipelines; turns CVPixelBuffers into textures
/// (zero-copy via CVMetalTextureCache) and runs an `Effect` or a pass-through copy into `output`.
///
/// Buffers: frame / plate / output must be IOSurface-backed 32BGRA (see `PixelBufferIO.make`);
/// mask is single-channel (OneComponent8 preferred; 16/32-bit float also accepted), any size.
public final class EffectRenderer {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let pipelines: PipelineCache

    private let textureCache: CVMetalTextureCache
    private let copyPipeline: MTLComputePipelineState
    private let emptyMask: MTLTexture
    private var effects: [EffectKind: Effect] = [:]

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw EffectError.noMetalDevice }
        self.device = device
        self.commandQueue = queue
        self.pipelines = PipelineCache(device: device)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { throw EffectError.textureCreation("CVMetalTextureCacheCreate failed") }
        self.textureCache = cache
        self.copyPipeline = try pipelines.compute("vc_copy", source: "")

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { throw EffectError.textureCreation("empty mask") }
        var zero: UInt8 = 0
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 1)
        self.emptyMask = tex
    }

    /// Shared instance of the effect for `kind` (created lazily). Returns nil for effects not yet implemented.
    /// To add one: implement `Effect` with an `init(pipelines:) throws` and add a case here.
    public func effect(_ kind: EffectKind) throws -> Effect? {
        if let e = effects[kind] { return e }
        let made: Effect?
        switch kind {
        case .dissolve: made = try DissolveEffect(pipelines: pipelines)
        case .substitution: made = try SubstitutionEffect(pipelines: pipelines)
        case .teleport: made = try TeleportEffect(pipelines: pipelines)
        }
        effects[kind] = made
        return made
    }

    /// Renders one frame. `effect == nil` is the pass-through fast path (frame copied to output).
    /// `plate == nil` falls back to the frame itself; `mask == nil` means "no person" (frame shown).
    /// When `waitUntilCompleted` is false the GPU work is committed and `completion` is called when
    /// the output buffer is ready. Returns false if textures could not be created.
    @discardableResult
    public func render(effect: Effect?, frame: CVPixelBuffer, plate: CVPixelBuffer?, mask: CVPixelBuffer?,
                       progress: Float, time: Float, reverse: Bool, into output: CVPixelBuffer,
                       waitUntilCompleted: Bool = true,
                       completion: (() -> Void)? = nil) -> Bool {
        guard let effect else { return passThrough(frame: frame, into: output, waitUntilCompleted: waitUntilCompleted, completion: completion) }
        guard let frameT = texture(frame), let outT = texture(output),
              let cb = commandQueue.makeCommandBuffer() else { return false }
        let plateT = plate.flatMap { texture($0) }
        let maskT = mask.flatMap { texture($0) }
        cb.label = "Effect \(effect.kind.rawValue)"
        effect.encode(into: cb, frame: frameT.texture, plate: plateT?.texture ?? frameT.texture,
                      mask: maskT?.texture ?? emptyMask,
                      progress: progress, time: time, reverse: reverse, output: outT.texture)
        submit(cb, keepAlive: [frameT, outT, plateT, maskT].compactMap { $0 }, wait: waitUntilCompleted, completion: completion)
        return true
    }

    /// Steady state (person absent): the effect's own look (log, lingering lines) or a plain plate copy.
    @discardableResult
    public func renderSteady(effect: Effect, frame: CVPixelBuffer, plate: CVPixelBuffer, time: Float,
                             into output: CVPixelBuffer) -> Bool {
        guard let frameT = texture(frame), let plateT = texture(plate), let outT = texture(output),
              let cb = commandQueue.makeCommandBuffer() else { return false }
        effect.encodeSteady(into: cb, frame: frameT.texture, plate: plateT.texture, time: time, output: outT.texture)
        submit(cb, keepAlive: [frameT, plateT, outT], wait: true, completion: nil)
        return true
    }

    /// macOS-background memory step (vc_bgmem): writes the updated `memory` and the halo-free `clean` frame.
    @discardableResult
    public func backgroundMemory(frame: CVPixelBuffer, previous: CVPixelBuffer, mask: CVPixelBuffer, fill: CVPixelBuffer,
                                 memory: CVPixelBuffer, clean: CVPixelBuffer,
                                 gain: SIMD3<Float> = .one, imageWeight: Float = 0, dilate: Float = 1,
                                 ringFollowsWeight: Bool = false) -> Bool {
        let ts = [frame, previous, mask, fill, memory, clean].compactMap { texture($0) }
        guard ts.count == 6, let pipe = try? pipelines.compute("vc_bgmem", source: ""),
              let cb = commandQueue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
        ts.enumerated().forEach { enc.setTexture($1.texture, index: $0) }
        var p = SIMD4<Float>(gain, imageWeight), d = SIMD2<Float>(dilate, ringFollowsWeight ? 1 : 0)
        enc.setBytes(&p, length: 16, index: 0)
        enc.setBytes(&d, length: 8, index: 1)
        enc.dispatchPerPixel(pipe, width: ts[4].texture.width, height: ts[4].texture.height)
        enc.endEncoding()
        submit(cb, keepAlive: ts, wait: true, completion: nil)
        return true
    }

    /// Copies `frame` into `output` (blit when sizes and formats match, otherwise a resampling kernel).
    @discardableResult
    public func passThrough(frame: CVPixelBuffer, into output: CVPixelBuffer,
                            waitUntilCompleted: Bool = true, completion: (() -> Void)? = nil) -> Bool {
        guard let src = texture(frame), let dst = texture(output),
              let cb = commandQueue.makeCommandBuffer() else { return false }
        let s = src.texture, d = dst.texture
        if s.width == d.width, s.height == d.height, s.pixelFormat == d.pixelFormat,
           let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: s, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: s.width, height: s.height, depth: 1),
                      to: d, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            blit.endEncoding()
        } else if let enc = cb.makeComputeCommandEncoder() {
            enc.setTexture(s, index: 0)
            enc.setTexture(d, index: 1)
            enc.dispatchPerPixel(copyPipeline, width: d.width, height: d.height)
            enc.endEncoding()
        }
        submit(cb, keepAlive: [src, dst], wait: waitUntilCompleted, completion: completion)
        return true
    }

    // MARK: - Internals

    /// Wraps a CVMetalTexture so the backing CV object stays alive until the GPU is done.
    private final class Wrapped {
        let cvTexture: CVMetalTexture
        let texture: MTLTexture
        init(_ cv: CVMetalTexture, _ t: MTLTexture) { cvTexture = cv; texture = t }
    }

    private func submit(_ cb: MTLCommandBuffer, keepAlive: [Wrapped], wait: Bool, completion: (() -> Void)?) {
        cb.addCompletedHandler { _ in
            withExtendedLifetime(keepAlive) {}
            completion?()
        }
        cb.commit()
        if wait { cb.waitUntilCompleted() }
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private func texture(_ pb: CVPixelBuffer) -> Wrapped? {
        let format: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_32BGRA: format = .bgra8Unorm
        case kCVPixelFormatType_OneComponent8: format = .r8Unorm
        case kCVPixelFormatType_OneComponent16Half: format = .r16Float
        case kCVPixelFormatType_OneComponent32Float: format = .r32Float
        default: return nil
        }
        let attrs = [kCVMetalTextureUsage: NSNumber(value: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue)] as CFDictionary
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, attrs, format,
            CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cvTex)
        guard status == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return Wrapped(cvTex, tex)
    }
}
