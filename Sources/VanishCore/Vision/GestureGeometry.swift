import CoreGraphics

/// Pure hand-geometry decisions (no Vision dependency, unit-testable).
/// Points are in aspect-corrected units (x scaled by width/height), y up.
public struct FingerJoints: Sendable, Codable {
    public var mcp: CGPoint, pip: CGPoint, tip: CGPoint
    public init(mcp: CGPoint, pip: CGPoint, tip: CGPoint) { self.mcp = mcp; self.pip = pip; self.tip = tip }
}

public struct HandJoints: Sendable, Codable {
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
    /// A real finger never reads beyond this ratio; above it Vision gave a degenerate palm (merged clasped hands).
    public var maxPlausibleRatio: CGFloat = 3.7
    /// V sign: ring/little count as folded when at most this far below the shorter of index/middle
    /// (a hand turned toward the camera foreshortens folded fingers to ~1.5-2.1; an open hand has ~0 gap).
    public var vFoldedGap: CGFloat = 0.3
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
    /// Interlaced seal (Vision merges both clasped hands into ONE hand with scrambled finger labels, so only the
    /// index finger is trusted): max tilt of wrist->index-tip from vertical, degrees.
    public var sealBlobMaxTiltDeg: CGFloat = 30
    /// ... min index extension ratio (merged hands read 1.5-2.1 across a 10 s clip).
    public var sealBlobMinIndexRatio: CGFloat = 1.5
    /// ... min wrist->index-tip length / face height (two clasped hands reach from the chest to the face).
    public var sealBlobMinReach: CGFloat = 0.9
    /// ... index tip must be within the face box widened by this fraction of its width, and below its top.
    public var sealBlobXMargin: CGFloat = 0.2
    /// Minimum joint confidence from Vision.
    public var minJointConfidence: Float = 0.1
    /// Wrist is often out of frame (hand raised close to the camera): Vision extrapolates it with low confidence.
    public var minWristConfidence: Float = 0.05
    /// Forehead box: expand face box horizontally by this fraction of its width.
    public var foreheadXMargin: CGFloat = 0.15
    /// Forehead box: extends above the face box top by this fraction of face height.
    public var foreheadTopMargin: CGFloat = 0.6
    /// Fallback if no eyebrow landmarks: forehead starts this fraction of face height below top.
    public var foreheadFallbackDepth: CGFloat = 0.33
    /// Width of the image the detector downscales to before running Vision.
    public var analysisWidth: Int = 1280
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

    static func vFoldedMax(_ h: HandJoints, _ c: GestureConfig) -> CGFloat {
        max(c.curledRatio, min(extensionRatio(h.index, wrist: h.wrist), extensionRatio(h.middle, wrist: h.wrist)) - c.vFoldedGap)
    }
    /// Index+middle extended and spread, ring+little folded.
    public static func isVSign(_ h: HandJoints, _ c: GestureConfig = .init()) -> Bool {
        let foldedMax = vFoldedMax(h, c)
        return isExtended(h.index, wrist: h.wrist, c) && isExtended(h.middle, wrist: h.wrist, c)
            && extensionRatio(h.ring, wrist: h.wrist) <= foldedMax && extensionRatio(h.little, wrist: h.wrist) <= foldedMax
            && tipSpread(h) >= c.vMinTipSpread && max(extensionRatio(h.index, wrist: h.wrist), extensionRatio(h.middle, wrist: h.wrist)) <= c.maxPlausibleRatio
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
    public static func tiltFromUp(_ h: HandJoints) -> CGFloat {
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
    /// Forehead region in normalized image coords (y up). `browTopY` = highest eyebrow point, if known.
    public static func foreheadRegion(faceBox f: CGRect, browTopY: CGFloat?, _ c: GestureConfig = .init()) -> CGRect {
        let bottom = browTopY ?? (f.maxY - c.foreheadFallbackDepth * f.height)
        let top = f.maxY + c.foreheadTopMargin * f.height
        let m = c.foreheadXMargin * f.width
        return CGRect(x: f.minX - m, y: bottom, width: f.width + 2 * m, height: max(top - bottom, 0))
    }

    // MARK: classification (pure, shared by the detector and the fixture tests)

    /// Priority: foreheadTwoFingers > handSeal (two hands) > vSign > handSeal (interlaced, merged into one hand). `face` may be nil (forehead + interlaced-seal tests need it).
    public static func classify(hands: [HandSample], face: FaceSample?, _ c: GestureConfig = .init()) -> Gesture {
        guard !hands.isEmpty else { return .none }
        let teleportish = hands.filter { isTeleportFingers($0.joints, c) }
        if let face {
            let region = face.forehead(c)
            if teleportish.contains(where: { region.contains($0.tip) }) { return .foreheadTwoFingers }
        }
        if hands.count == 2, isHandSeal(hands[0].joints, hands[1].joints, c) { return .handSeal }
        if hands.contains(where: { isVSign($0.joints, c) }) { return .vSign }
        if let face, hands.count == 1, sealBlobChecks(hands[0], face, c).allSatisfy(\.pass) { return .handSeal }
        return .none
    }

    // MARK: debug readouts: every rule's measured value next to its threshold

    /// Per-gesture rule values for one hand. Mirrors the `is*` rules above (tip-above-pip is not shown).
    public static func readouts(_ h: HandJoints, _ c: GestureConfig = .init()) -> [GestureReadout] {
        let r = { (f: FingerJoints) in extensionRatio(f, wrist: h.wrist) }
        let (i, m, g, l) = (r(h.index), r(h.middle), r(h.ring), r(h.little))
        let spread = tipSpread(h)
        let longest = max(i, m) - 0.2
        let vMax = vFoldedMax(h, c)
        return [
            GestureReadout(gesture: "V sign (dissolve)", checks: [
                .init(name: "index ext", value: i, threshold: c.extendedRatio, atLeast: true),
                .init(name: "middle ext", value: m, threshold: c.extendedRatio, atLeast: true),
                .init(name: "ring curl", value: g, threshold: vMax, atLeast: false),
                .init(name: "little curl", value: l, threshold: vMax, atLeast: false),
                .init(name: "tip spread", value: spread, threshold: c.vMinTipSpread, atLeast: true),
                .init(name: "max ext (sane)", value: max(i, m), threshold: c.maxPlausibleRatio, atLeast: false)]),
            GestureReadout(gesture: "Teleport fingers (needs forehead)", checks: [
                .init(name: "index ext", value: i, threshold: c.curledRatio, atLeast: true),
                .init(name: "middle ext", value: m, threshold: c.curledRatio, atLeast: true),
                .init(name: "tip spread", value: spread, threshold: 0.4, atLeast: false),
                .init(name: "ring < longest-0.2", value: g, threshold: longest, atLeast: false),
                .init(name: "little < longest-0.2", value: l, threshold: longest, atLeast: false)]),
        ]
    }

    /// Interlaced seal seen as one merged hand: index finger up, long, vertical, in front of the face.
    public static func sealBlobChecks(_ h: HandSample, _ f: FaceSample, _ c: GestureConfig = .init()) -> [RuleCheck] {
        let j = h.joints, box = f.box, m = c.sealBlobXMargin * box.width
        return [
            .init(name: "index ext", value: extensionRatio(j.index, wrist: j.wrist), threshold: c.sealBlobMinIndexRatio, atLeast: true),
            .init(name: "tilt deg", value: tiltFromUp(j), threshold: c.sealBlobMaxTiltDeg, atLeast: false),
            .init(name: "reach / face h", value: dist(j.wrist, j.index.tip) / max(box.height, 1e-6), threshold: c.sealBlobMinReach, atLeast: true),
            .init(name: "tip x in face (0 = inside)", value: max(box.minX - m - h.tip.x, h.tip.x - box.maxX - m, 0), threshold: 0, atLeast: false),
            .init(name: "tip below face top", value: box.maxY - h.tip.y, threshold: 0.25, atLeast: true)]
    }

    /// Two-hand seal rules (palm = mean of both palms).
    public static func sealReadout(_ a: HandJoints, _ b: HandJoints, _ c: GestureConfig = .init()) -> GestureReadout {
        let palm = (a.palm + b.palm) / 2
        var checks: [RuleCheck] = [
            .init(name: "wrist dist", value: dist(a.wrist, b.wrist) / palm, threshold: c.sealMaxWristDist, atLeast: false),
            .init(name: "index tip dist", value: dist(a.index.tip, b.index.tip) / palm, threshold: c.sealMaxTipDist, atLeast: false)]
        for (n, h) in [("A", a), ("B", b)] {
            checks += [
                .init(name: "\(n) index ext", value: extensionRatio(h.index, wrist: h.wrist), threshold: c.extendedRatio, atLeast: true),
                .init(name: "\(n) tilt deg", value: tiltFromUp(h), threshold: c.sealMaxTiltDeg, atLeast: false),
                .init(name: "\(n) ring not ext", value: extensionRatio(h.ring, wrist: h.wrist), threshold: c.extendedRatio, atLeast: false),
                .init(name: "\(n) little not ext", value: extensionRatio(h.little, wrist: h.wrist), threshold: c.extendedRatio, atLeast: false)]
        }
        return GestureReadout(gesture: "Hand seal, two hands (substitution)", checks: checks)
    }
}

/// One rule: measured `value` vs `threshold` (`atLeast`: passes when value >= threshold, else <=).
public struct RuleCheck: Sendable, Codable {
    public var name: String, value: CGFloat, threshold: CGFloat, atLeast: Bool
    public var pass: Bool { atLeast ? value >= threshold : value <= threshold }
}
public struct GestureReadout: Sendable, Codable {
    public var gesture: String, checks: [RuleCheck]
    public var pass: Bool { checks.allSatisfy(\.pass) }
}

/// A hand as the classifier sees it: aspect-corrected joints + fingertip midpoint in normalized image coords.
public struct HandSample: Sendable, Codable {
    public var joints: HandJoints, tip: CGPoint
    public init(joints: HandJoints, tip: CGPoint) { self.joints = joints; self.tip = tip }
}
public struct FaceSample: Sendable, Codable {
    public var box: CGRect, browTopY: CGFloat?
    public init(box: CGRect, browTopY: CGFloat?) { self.box = box; self.browTopY = browTopY }
    public func forehead(_ c: GestureConfig = .init()) -> CGRect { GestureGeometry.foreheadRegion(faceBox: box, browTopY: browTopY, c) }
}
/// A recorded problem frame (debug window "Record"): replay it in a unit test with `GestureGeometry.classify`.
public struct GestureFixture: Sendable, Codable {
    public var expected: Gesture, hands: [HandSample], face: FaceSample?
    public init(expected: Gesture, hands: [HandSample], face: FaceSample?) { self.expected = expected; self.hands = hands; self.face = face }
}
