import CoreGraphics

/// Pure hand-geometry decisions (no Vision dependency, unit-testable).
/// Points are in aspect-corrected units (x scaled by width/height), y up.
public struct FingerJoints: Sendable {
    public var mcp: CGPoint, pip: CGPoint, tip: CGPoint
    public init(mcp: CGPoint, pip: CGPoint, tip: CGPoint) { self.mcp = mcp; self.pip = pip; self.tip = tip }
}

public struct HandJoints: Sendable {
    public var wrist: CGPoint
    public var index, middle, ring, little: FingerJoints
    public init(wrist: CGPoint, index: FingerJoints, middle: FingerJoints, ring: FingerJoints, little: FingerJoints) {
        self.wrist = wrist; self.index = index; self.middle = middle; self.ring = ring; self.little = little
    }
    /// Palm length (wrist -> middle MCP): the scale reference for every ratio below.
    public var palm: CGFloat { max(dist(wrist, middle.mcp), 1e-6) }
}

@inline(__always) func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

public struct GestureConfig: Sendable {
    /// tip-to-wrist / mcp-to-wrist at or above this = extended (straight finger is ~2.0-2.4).
    public var extendedRatio: CGFloat = 1.7
    /// ... at or below this = curled (fist is ~1.0-1.3).
    public var curledRatio: CGFloat = 1.5
    /// Minimum tip-to-tip distance / palm length for a "V".
    public var vMinTipSpread: CGFloat = 0.35
    /// Maximum tip-to-tip distance / palm length for "two fingers together".
    public var togetherMaxTipSpread: CGFloat = 0.30
    /// Hand seal: max wrist distance / palm length.
    public var sealMaxWristDist: CGFloat = 1.6
    /// Hand seal: max index-fingertip distance / palm length.
    public var sealMaxTipDist: CGFloat = 0.6
    /// Hand seal: max deviation of wrist->index-tip from vertical, degrees.
    public var sealMaxTiltDeg: CGFloat = 35
    /// Hand seal seen as one hand: max tilt (the teleport forehead sign is the same shape, tilted ~45°).
    public var sealOneHandMaxTiltDeg: CGFloat = 25
    /// Minimum joint confidence from Vision.
    public var minJointConfidence: Float = 0.3
    /// Forehead box: expand face box horizontally by this fraction of its width.
    public var foreheadXMargin: CGFloat = 0.15
    /// Forehead box: extends above the face box top by this fraction of face height.
    public var foreheadTopMargin: CGFloat = 0.6
    /// Fallback if no eyebrow landmarks: forehead starts this fraction of face height below top.
    public var foreheadFallbackDepth: CGFloat = 0.33
    /// Width of the image the detector downscales to before running Vision.
    public var analysisWidth: Int = 640
    public init() {}
}

public enum GestureGeometry {
    public static func extensionRatio(_ f: FingerJoints, wrist: CGPoint) -> CGFloat {
        dist(f.tip, wrist) / max(dist(f.mcp, wrist), 1e-6)
    }
    public static func isExtended(_ f: FingerJoints, wrist: CGPoint, _ c: GestureConfig = .init()) -> Bool {
        extensionRatio(f, wrist: wrist) >= c.extendedRatio && dist(f.tip, wrist) > dist(f.pip, wrist)
    }
    public static func isCurled(_ f: FingerJoints, wrist: CGPoint, _ c: GestureConfig = .init()) -> Bool {
        extensionRatio(f, wrist: wrist) <= c.curledRatio
    }
    static func tipSpread(_ h: HandJoints) -> CGFloat { dist(h.index.tip, h.middle.tip) / h.palm }

    /// Index+middle extended and spread, ring+little curled.
    public static func isVSign(_ h: HandJoints, _ c: GestureConfig = .init()) -> Bool {
        isExtended(h.index, wrist: h.wrist, c) && isExtended(h.middle, wrist: h.wrist, c)
            && isCurled(h.ring, wrist: h.wrist, c) && isCurled(h.little, wrist: h.wrist, c)
            && tipSpread(h) >= c.vMinTipSpread
    }
    /// Index+middle extended and adjacent, ring+little curled.
    public static func isTwoFingersTogether(_ h: HandJoints, _ c: GestureConfig = .init()) -> Bool {
        isExtended(h.index, wrist: h.wrist, c) && isExtended(h.middle, wrist: h.wrist, c)
            && isCurled(h.ring, wrist: h.wrist, c) && isCurled(h.little, wrist: h.wrist, c)
            && tipSpread(h) <= c.togetherMaxTipSpread
    }
    /// Teleport sign (checked only at the forehead, so looser): index+middle out and together, clearly
    /// longer than ring+little. Seen from the front, folded fingers foreshorten and look half-extended.
    public static func isTeleportFingers(_ h: HandJoints, _ c: GestureConfig = .init()) -> Bool {
        let i = extensionRatio(h.index, wrist: h.wrist), m = extensionRatio(h.middle, wrist: h.wrist)
        let longest = max(i, m) - 0.2
        return min(i, m) >= c.curledRatio && tipSpread(h) <= 0.4
            && extensionRatio(h.ring, wrist: h.wrist) < longest && extensionRatio(h.little, wrist: h.wrist) < longest
    }
    /// Angle (deg) between wrist->index-tip and straight up (+y).
    static func tiltFromUp(_ h: HandJoints) -> CGFloat {
        let v = CGPoint(x: h.index.tip.x - h.wrist.x, y: h.index.tip.y - h.wrist.y)
        return abs(atan2(v.x, v.y)) * 180 / .pi
    }
    /// Hand seal: hands clasped (wrists close), both index fingers extended, up and touching,
    /// ring + little folded (interlaced). Prayer hands (all fingers up) do not count.
    public static func isHandSeal(_ a: HandJoints, _ b: HandJoints, _ c: GestureConfig = .init()) -> Bool {
        let palm = (a.palm + b.palm) / 2
        guard dist(a.wrist, b.wrist) / palm <= c.sealMaxWristDist,
              dist(a.index.tip, b.index.tip) / palm <= c.sealMaxTipDist else { return false }
        for h in [a, b] {
            guard h.index.tip.y > h.wrist.y, tiltFromUp(h) <= c.sealMaxTiltDeg, isExtended(h.index, wrist: h.wrist, c),
                  !isExtended(h.ring, wrist: h.wrist, c), !isExtended(h.little, wrist: h.wrist, c) else { return false }
        }
        return true
    }
    /// Vision usually merges the clasped hands into one: the two index fingers read as index+middle
    /// together pointing straight up, the interlaced fingers as folded.
    public static func isHandSealOneHand(_ h: HandJoints, _ c: GestureConfig = .init()) -> Bool {
        isTwoFingersTogether(h, c) && h.index.tip.y > h.wrist.y && tiltFromUp(h) <= c.sealOneHandMaxTiltDeg
    }

    /// Curl of one finger without the wrist: tip-to-MCP / MCP-to-PIP (straight ~2.0+, folded < 1).
    /// A finger Vision didn't see (all three joints at one point) reads 0 = folded.
    static func curl(_ f: FingerJoints) -> CGFloat {
        let seg = dist(f.mcp, f.pip)
        return seg < 1e-6 ? 0 : dist(f.tip, f.mcp) / seg
    }
    /// Wrist-free hand size: index MCP <-> little MCP, else 2 x index MCP->PIP (little not seen).
    // ponytail: the 2x fallback is a rough palm-width/phalanx ratio; per-user ratio from calibration if it matters.
    static func palmWidth(_ h: HandJoints) -> CGFloat {
        let w = dist(h.index.mcp, h.little.mcp)
        return max(w > 1e-6 ? w : 2 * dist(h.index.mcp, h.index.pip), 1e-6)
    }

    /// Bump when `features` changes: saved calibrations of another version are dropped (`GestureSamples`).
    public static let featureVersion = 2
    /// Fixed-length feature vector for the kNN classifier (`GestureSamples`). Never reads the wrist, so a hand
    /// with only its index finger (MCP, PIP, tip) in view works. Hands sorted by index MCP x, max 2, a missing
    /// hand is zeros. Per hand: 4 curls, index-middle tip spread / palm width, index MCP->tip tilt / 90,
    /// index tip relative to the face centre / face height (x, y; 0 without a face).
    /// Then: index MCP distance and index-tip distance / mean palm width (0 with < 2 hands), face seen (0/1),
    /// hand count (last, the calibration UI reads it).
    /// `face`: face box in the same aspect-corrected units as the joints.
    public static let featureCount = 2 * 8 + 4
    public static func features(_ hands: [HandJoints], face: CGRect? = nil) -> [Double] {
        let hs = Array(hands.sorted { $0.index.mcp.x < $1.index.mcp.x }.prefix(2))
        var f: [CGFloat] = []
        for k in 0..<2 {
            guard k < hs.count else { f += Array(repeating: 0, count: 8); continue }
            let h = hs[k], tip = h.index.tip
            let v = CGPoint(x: tip.x - h.index.mcp.x, y: tip.y - h.index.mcp.y)
            f += [h.index, h.middle, h.ring, h.little].map(curl)
            f += [dist(h.index.tip, h.middle.tip) / palmWidth(h), abs(atan2(v.x, v.y)) * 180 / .pi / 90]
            if let face, face.height > 1e-6 {
                f += [(tip.x - face.midX) / face.height, (tip.y - face.midY) / face.height]
            } else {
                f += [0, 0]
            }
        }
        if hs.count == 2 {
            let palm = (palmWidth(hs[0]) + palmWidth(hs[1])) / 2
            f += [dist(hs[0].index.mcp, hs[1].index.mcp) / palm, dist(hs[0].index.tip, hs[1].index.tip) / palm]
        } else {
            f += [0, 0]
        }
        f.append(face == nil ? 0 : 1)
        f.append(CGFloat(hs.count))
        return f.map(Double.init)
    }

    /// Forehead region in normalized image coords (y up). `browTopY` = highest eyebrow point, if known.
    public static func foreheadRegion(faceBox f: CGRect, browTopY: CGFloat?, _ c: GestureConfig = .init()) -> CGRect {
        let bottom = browTopY ?? (f.maxY - c.foreheadFallbackDepth * f.height)
        let top = f.maxY + c.foreheadTopMargin * f.height
        let m = c.foreheadXMargin * f.width
        return CGRect(x: f.minX - m, y: bottom, width: f.width + 2 * m, height: max(top - bottom, 0))
    }
}
