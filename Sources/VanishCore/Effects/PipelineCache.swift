import Foundation
import Metal

public enum EffectError: Error, CustomStringConvertible {
    case noMetalDevice
    case shaderCompile(String)
    case missingFunction(String)
    case textureCreation(String)
    case io(String)

    public var description: String {
        switch self {
        case .noMetalDevice: return "No Metal device available"
        case .shaderCompile(let m): return "Metal shader compile failed: \(m)"
        case .missingFunction(let n): return "Metal function not found: \(n)"
        case .textureCreation(let m): return "Texture creation failed: \(m)"
        case .io(let m): return "I/O error: \(m)"
        }
    }
}

/// Compiles Metal source at runtime (no metallib / Metal toolchain needed at build time) and caches
/// libraries and compute pipelines. Every effect source is prefixed with `ShaderCommon.source`.
///
/// Adding an effect: write a `static let metalSource` with one or more `kernel`s, then in `init`
/// call `try pipelines.compute("myKernel", source: Self.metalSource)`.
public final class PipelineCache {
    public let device: MTLDevice
    private var libraries: [String: MTLLibrary] = [:]
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private let lock = NSLock()

    public init(device: MTLDevice) { self.device = device }

    /// Library for `source` (common header prepended). Cached by source text.
    public func library(source: String) throws -> MTLLibrary {
        lock.lock(); defer { lock.unlock() }
        return try libraryLocked(source: source)
    }

    private func libraryLocked(source: String) throws -> MTLLibrary {
        if let lib = libraries[source] { return lib }
        let options = MTLCompileOptions()   // fast math is the default
        do {
            let lib = try device.makeLibrary(source: ShaderCommon.source + "\n" + source, options: options)
            libraries[source] = lib
            return lib
        } catch {
            throw EffectError.shaderCompile("\(error)")
        }
    }

    /// Compute pipeline for kernel `function` in `source`. Cached by (source, function).
    public func compute(_ function: String, source: String) throws -> MTLComputePipelineState {
        lock.lock(); defer { lock.unlock() }
        let key = function + "\u{0}" + source
        if let p = pipelines[key] { return p }
        let lib = try libraryLocked(source: source)
        guard let fn = lib.makeFunction(name: function) else { throw EffectError.missingFunction(function) }
        let p = try device.makeComputePipelineState(function: fn)
        pipelines[key] = p
        return p
    }
}

public extension MTLComputeCommandEncoder {
    /// Dispatch one thread per output pixel.
    func dispatchPerPixel(_ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }
}

/// Shared Metal helpers available to every effect kernel.
public enum ShaderCommon {
    public static let source = #"""
#include <metal_stdlib>
using namespace metal;

constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

inline float vc_hash21(float2 p) {
    p = fract(p * float2(233.34, 851.73));
    p += dot(p, p + 23.45);
    return fract(p.x * p.y);
}

inline float2 vc_hash22(float2 p) {
    float n = vc_hash21(p);
    return float2(n, vc_hash21(p + n + 17.0));
}

inline float vc_valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = vc_hash21(i);
    float b = vc_hash21(i + float2(1, 0));
    float c = vc_hash21(i + float2(0, 1));
    float d = vc_hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float vc_fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 4; i++) {
        v += amp * vc_valueNoise(p);
        p = p * 2.03 + float2(11.7, 5.3);
        amp *= 0.5;
    }
    return v / 0.9375;
}

inline float vc_easeInOutCubic(float t) {
    t = saturate(t);
    return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5;
}

/// Pass-through with resampling (used when frame and output sizes differ).
kernel void vc_copy(texture2d<float, access::sample> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    dst.write(src.sample(linearClamp, uv), gid);
}

/// Person over plate: mix(plate * exposure, frame, mask * personAlpha), then an optional white flash
/// over a blurred mask (Teleport).
struct VCBlendParams { float personAlpha; float flash; float2 pad; };
kernel void vc_blend(texture2d<float, access::sample> frame [[texture(0)]],
                     texture2d<float, access::sample> plate [[texture(1)]],
                     texture2d<float, access::sample> mask  [[texture(2)]],
                     texture2d<float, access::write>  outTex [[texture(3)]],
                     constant VCBlendParams& P [[buffer(0)]],
                     constant float4& E [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    uint W = outTex.get_width(), H = outTex.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    float3 bg = plate.sample(linearClamp, uv).rgb * E.rgb;
    float3 col = mix(bg, frame.sample(linearClamp, uv).rgb, mask.sample(linearClamp, uv).r * P.personAlpha);
    if (P.flash > 0.0) {
        float g = 0.0;   // 5x5 box over ~4% of the frame ≈ GaussianBlur(sigma 10) at 720p
        for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++)
            g += mask.sample(linearClamp, uv + float2(x, y) * float2(0.008, 0.014)).r;
        col = mix(col, float3(1.0), saturate(g / 25.0) * P.flash * 0.85);
    }
    outTex.write(float4(saturate(col), 1.0), gid);
}


/// Background for synthetic (macOS) backgrounds. `d` = mask dilated by ~3% (catches the halo macOS
/// leaves around the person). Visible pixels: frame; hidden: the macOS image (alpha 1) or the coarse
/// fill. `clean` = frame with the halo ring replaced by that background.
kernel void vc_bgmem(texture2d<float, access::sample> frame [[texture(0)]],
                     texture2d<float, access::sample> prev  [[texture(1)]],
                     texture2d<float, access::sample> mask  [[texture(2)]],
                     texture2d<float, access::sample> fill  [[texture(3)]],
                     texture2d<float, access::write>  mem   [[texture(4)]],
                     texture2d<float, access::write>  clean [[texture(5)]],
                     constant float4& P [[buffer(0)]],   // rgb = global gain on the image, w = image weight
                     constant float2& R [[buffer(1)]],   // x = dilation scale, y = 1: halo ring follows the image weight
                     uint2 gid [[thread_position_in_grid]]) {
    uint W = mem.get_width(), H = mem.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 uv = (float2(gid) + 0.5) / float2(W, H);
    float m = mask.sample(linearClamp, uv).r, d = m;
    for (int i = 0; i < 12; i++) {
        float a = float(i) * 0.5236;
        float2 o = float2(cos(a) * 0.018, sin(a) * 0.032) * R.x;
        d = max(d, mask.sample(linearClamp, uv + o).r);
        d = max(d, mask.sample(linearClamp, uv + o * 0.5).r);
    }
    float3 f = frame.sample(linearClamp, uv).rgb;
    float4 p = prev.sample(linearClamp, uv);
    bool visible = d < 0.04;
    float3 img = p.a > 0.5 ? p.rgb * P.rgb : fill.sample(linearClamp, uv).rgb;
    float3 bg = mix(visible ? f : img, img, P.w);   // w -> 1: whole frame becomes the image (no seams)
    if (R.y > 0.5) {
        // real room: the plate's colour differs a bit from live, so blend it in with a wide soft
        // gradient around the person (blurred mask, ~8% of the frame) instead of a seam
        float b = 0.0;
        for (int y = -2; y <= 2; y++) for (int x = -2; x <= 2; x++)
            b += mask.sample(linearClamp, uv + float2(x, y) * float2(0.02, 0.035)).r;
        // nothing at the start (pure live): the ring around the person comes in over the first 30%,
        // the whole frame only in the second half -> no early see-through
        float iw = max(smoothstep(0.5, 1.0, P.w), smoothstep(0.05, 0.5, b / 25.0) * smoothstep(0.0, 0.3, P.w));
        float3 soft = mix(f, img, iw);
        mem.write(float4(img, 1.0), gid);   // behind the person: pure plate, no live edge pixels (ghosts)
        clean.write(float4(mix(soft, f, smoothstep(0.4, 0.8, m)), 1.0), gid);
        return;
    }
    mem.write(float4(bg, 1.0), gid);
    clean.write(float4(visible ? mix(f, img, P.w) : mix(bg, f, smoothstep(0.4, 0.8, m)), 1.0), gid);
}
"""#
}
