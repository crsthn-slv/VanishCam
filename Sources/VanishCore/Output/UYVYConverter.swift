import Metal
import CoreVideo

/// BGRA -> UYVY (2vuy) on the GPU. The Core Image path cannot render into 422 buffers (writes zeros),
/// so this compiles its own kernel and copies the result into pooled UYVY pixel buffers.
/// ponytail: BT.601 full-range->studio constants; BT.709 if colours ever look off.
public final class UYVYConverter {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var pool: CVPixelBufferPool?
    private var size = (0, 0)

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    static inline float yLuma(float4 p) { return 16.0h + 65.738h * p.r + 129.057h * p.g + 25.064h * p.b; }
    static inline float yCb(float4 p)   { return 128.0h - 37.945h * p.r - 74.494h * p.g + 112.439h * p.b; }
    static inline float yCr(float4 p)   { return 128.0h + 112.439h * p.r - 94.154h * p.g - 18.285h * p.b; }
    kernel void bgra2uyvy2(texture2d<float, access::read> src [[texture(0)]],
                           device uchar4 *out [[buffer(0)]],
                           uint2 pos [[thread_position_in_grid]]) {
        uint w = src.get_width(), x0 = pos.x * 2, y = pos.y;
        if (x0 + 1 >= w) return;
        float4 a = src.read(uint2(x0, y));
        float4 b = src.read(uint2(x0 + 1, y));
        // BT.601 full-range RGB -> studio YCbCr
        out[y * (w / 2) + pos.x] = uchar4(uchar(yCb(a)), uchar(yLuma(a)), uchar(yCr(a)), uchar(yLuma(b)));
    }
    """

    private var texCache: CVMetalTextureCache?
    public init(device: any MTLDevice = MTLCreateSystemDefaultDevice()!, queue: (any MTLCommandQueue)? = nil) throws {
        self.device = device
        CVMetalTextureCacheCreate(nil, nil, device, nil, &texCache)
        let lib = try device.makeLibrary(source: Self.source, options: nil)
        guard let fn = lib.makeFunction(name: "bgra2uyvy2") else { throw EffectError.shaderCompile("bgra2uyvy") }
        pipeline = try device.makeComputePipelineState(function: fn)
        self.queue = queue ?? device.makeCommandQueue()!
    }

    public func convert(_ bgra: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(bgra), h = CVPixelBufferGetHeight(bgra)
        if pool == nil || size != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr8,
                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]   // cross-process: the OBS extension reads via IOSurface
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool); size = (w, h)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out,
              let srcTex = texture(bgra), let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder(), let buf = device.makeBuffer(length: w * h * 2) else { return nil }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(srcTex, index: 0)
        enc.setBuffer(buf, offset: 0, index: 0)
        let g = MTLSize(width: (w / 2 + 31) / 32, height: (h + 7) / 8, depth: 1)   // one thread per pixel pair
        let t = MTLSize(width: 32, height: 8, depth: 1)
        enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
        enc.endEncoding()
        enc.label = "bgra2uyvy"
        cb.commit(); cb.waitUntilCompleted()
        CVPixelBufferLockBaseAddress(out, [])
        memcpy(CVPixelBufferGetBaseAddress(out)!, buf.contents(), min(w * h * 2, CVPixelBufferGetDataSize(out)))
        CVPixelBufferUnlockBaseAddress(out, [])
        return out
    }

    private func texture(_ pb: CVPixelBuffer) -> MTLTexture? {
        var tex: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, texCache!, pb, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &tex)
        return tex.flatMap { CVMetalTextureGetTexture($0) }
    }
}
