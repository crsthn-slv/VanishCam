import Foundation
import Metal

/// Normal vanish: the masked person burns away from the feet up along a noisy front with a
/// cyan glow band and drifting ash specks, revealing the background plate. ~3.6 s.
public final class DissolveEffect: Effect {
    public let kind: EffectKind = .dissolve
    public let duration: Double = 1.6   // linear timing: no slow smouldering tail on the head
    /// Per-channel gain applied to the plate so its brightness matches the live frame (camera auto-exposure drifts).
    public var exposure: SIMD3<Float> = .init(1, 1, 1)

    private let pipeline: MTLComputePipelineState

    public init(pipelines: PipelineCache) throws {
        pipeline = try pipelines.compute("vc_dissolve", source: Self.metalSource)
    }

    private struct Params {
        var progress: Float   // already direction-corrected: 0 = person fully visible, 1 = gone
        var time: Float
        var aspect: Float
        var pad: Float = 0
    }

    public func encode(into commandBuffer: MTLCommandBuffer,
                       frame: MTLTexture, plate: MTLTexture, mask: MTLTexture,
                       progress: Float, time: Float, reverse: Bool, output: MTLTexture) {
        let p = min(max(progress, 0), 1)
        var params = Params(progress: reverse ? 1 - p : p,
                            time: time,
                            aspect: Float(output.width) / Float(max(output.height, 1)))
        guard let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.label = "Dissolve"
        var expo = SIMD4<Float>(exposure.x, exposure.y, exposure.z, 0)
        enc.setTexture(frame, index: 0)
        enc.setTexture(plate, index: 1)
        enc.setTexture(mask, index: 2)
        enc.setTexture(output, index: 3)
        enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        enc.setBytes(&expo, length: 16, index: 1)
        enc.dispatchPerPixel(pipeline, width: output.width, height: output.height)
        enc.endEncoding()
    }

    static let metalSource = #"""
struct DissolveParams { float progress; float time; float aspect; float pad; };
struct Exposure { float4 rgba; };   // rgb = per-channel scale matching plate to the live frame

// Burn-front field in [0,1]: low values dissolve first. Mostly a bottom-to-top ramp, broken up by
// smooth noise (ragged front), per-grain noise (sandy edge) and a gentle horizontal ripple.
inline float dissolve_field(float2 uv, float2 pix, float aspect, float time) {
    float2 p = float2(uv.x * aspect, uv.y);
    float ramp   = (1.0 - uv.y) * 0.70;
    float smooth = vc_fbm(p * 7.0 + float2(0.0, time * 0.04)) * 0.20;
    float grain  = vc_hash21(floor(pix * 0.5)) * 0.07;
    float ripple = sin(uv.x * 18.0) * 0.025;
    return saturate(ramp + smooth + grain + ripple);
}

kernel void vc_dissolve(texture2d<float, access::sample> frame [[texture(0)]],
                        texture2d<float, access::sample> plate [[texture(1)]],
                        texture2d<float, access::sample> mask  [[texture(2)]],
                        texture2d<float, access::write>  outTex [[texture(3)]],
                        constant DissolveParams& P [[buffer(0)]],
                        constant Exposure& E [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint W = outTex.get_width(), H = outTex.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 pix = float2(gid);
    float2 uv = (pix + 0.5) / float2(W, H);

    float4 cam = frame.sample(linearClamp, uv);
    if (P.progress <= 0.0) { outTex.write(float4(cam.rgb, 1.0), gid); return; }
    float3 bg = plate.sample(linearClamp, uv).rgb * E.rgba.rgb;   // exposure-matched plate
    // mask grown ~1.5% and firmed up: the soft silhouette edge counts as person, so it dissolves with
    // the front instead of staying behind as a thin outline
    float mr = mask.sample(linearClamp, uv).r;
    for (int i = 0; i < 8; i++) {
        float a = float(i) * 0.7854;
        mr = max(mr, mask.sample(linearClamp, uv + float2(cos(a) * 0.009, sin(a) * 0.016)).r);
    }
    float m = smoothstep(0.03, 0.35, mr);

    // Threshold sweeps slightly past [0,1] so progress 0 / 1 are exactly "all there" / "all gone".
    const float w = 0.055;
    float e = P.progress;   // linear: constant front speed, head goes quickly at the end
    float thr = e * (1.0 + 2.0 * w) - w;
    float field = dissolve_field(uv, pix, P.aspect, P.time);
    float survival = smoothstep(thr - w, thr + w, field);
    // plus a soft fade of whatever is left over the last third: no pixelated head lingering at the end
    float3 col = mix(cam.rgb, bg, m * max(1.0 - survival, smoothstep(0.65, 1.0, e)));

    // Neutral dust: sparse specks drifting up just behind the front. No glow band, no colour tint
    // (the original effect has no outline around the silhouette).
    float2 ap = float2(uv.x * P.aspect + sin(uv.y * 9.0 + P.time * 1.3) * 0.006,
                       uv.y + P.time * 0.06) * 90.0;
    float2 cell = floor(ap);
    float2 rnd = vc_hash22(cell);
    float exists = step(0.82, vc_hash21(cell + 3.1));
    float speck = 1.0 - smoothstep(0.08, 0.22, length(fract(ap) - (0.2 + 0.6 * rnd)));
    float behind = thr - field;
    float trail = step(0.0, behind) * (1.0 - smoothstep(0.0, 0.10, behind));
    float mDust = saturate((mask.sample(linearClamp, uv + float2(0.0, 0.03)).r - 0.3) / 0.4);
    float dust = speck * exists * trail * mDust * 0.55;
    const float3 cyan = float3(0.35, 0.80, 1.0);
    col = mix(col, cyan, dust);
    // blue glow along the burn front (on the person only)
    float front = 1.0 - smoothstep(0.0, 0.045, abs(field - thr));
    col += cyan * front * m * 0.55 * (1.0 - smoothstep(0.85, 1.0, e));

    // last 20%: the whole frame converges to the background regardless of the mask, so the soft mask
    // edge can't leave an outline of the person at the end (or at the start of the return)
    col = mix(col, bg, smoothstep(0.8, 1.0, e));
    outTex.write(float4(saturate(col), 1.0), gid);
}
"""#
}
