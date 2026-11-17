import Accelerate
import CoreVideo
import Foundation
import Vision

/// Apple Vision gesture detector. Call from one background queue (internally locked anyway).
/// Rules (no calibration): foreheadTwoFingers > handSeal > vSign. With calibration `samples`, kNN decides all three.
public final class VisionGestureDetector: GestureDetecting {
    public var config: GestureConfig
    private let lock = NSLock()
    private let handler = VNSequenceRequestHandler()
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private var recentFace: (box: CGRect, at: Date)?
    private var scaled: CVPixelBuffer?
    private var _samples: GestureSamples?
    private var _lastFeatures: [Double]?
    private var _lastDistance: Double?
    private var _lastHands: [[VNHumanHandPoseObservation.JointName: CGPoint]] = []

    /// Per-user calibration. Non-empty = kNN decides vSign/handSeal/teleport.
    public var samples: GestureSamples? {
        get { lock.lock(); defer { lock.unlock() }; return _samples }
        set { let p = newValue?.prepared(); lock.lock(); _samples = p; lock.unlock() }
    }
    /// Feature vector of the last analyzed frame (zeros with count 0 when no hand), for calibration capture.
    public var lastFeatures: [Double]? { lock.lock(); defer { lock.unlock() }; return _lastFeatures }
    /// Joints (normalized, y up, confidence >= minJointConfidence) of each hand in the last frame, for the calibration preview.
    public var lastHands: [[VNHumanHandPoseObservation.JointName: CGPoint]] { lock.lock(); defer { lock.unlock() }; return _lastHands }
    /// Run face detection every frame (calibration capture needs the face-relative features).
    public var alwaysDetectFace = false
    /// Nearest-sample distance of the last kNN decision (debug).
    public var lastDistance: Double? { lock.lock(); defer { lock.unlock() }; return _lastDistance }

    public init(config: GestureConfig = .init()) {
        self.config = config
        handRequest.maximumHandCount = 2
    }

    public func detect(in pixelBuffer: CVPixelBuffer) -> Gesture {
        lock.lock(); defer { lock.unlock() }
        guard let small = downscale(pixelBuffer) else { _lastHands = []; return .none }
        do { try handler.perform([handRequest], on: small) } catch { _lastHands = []; return .none }
        let obs = handRequest.results ?? []
        _lastHands = obs.map { o in
            var d: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
            for (n, r) in (try? o.recognizedPoints(.all)) ?? [:] where r.confidence >= config.minJointConfidence { d[n] = r.location }
            return d
        }
        let aspect = CGFloat(CVPixelBufferGetWidth(small)) / CGFloat(CVPixelBufferGetHeight(small))
        // Keep normalized tips too: needed for forehead test (face box is normalized).
        // Any hand with its index finger in view goes to kNN; the rules also need the wrist.
        let all: [(joints: HandJoints, hasWrist: Bool, indexTip: CGPoint, middleTip: CGPoint)] = obs.compactMap { o in
            guard let h = joints(from: o, aspect: aspect) else { return nil }
            let p = { (n: VNHumanHandPoseObservation.JointName) -> CGPoint? in
                guard let r = try? o.recognizedPoint(n) else { return nil }; return r.location }
            return (h.joints, h.hasWrist, p(.indexTip) ?? .zero, p(.middleTip) ?? .zero)
        }
        let hands = all.filter(\.hasWrist)
        let knn = (_samples?.isEmpty == false) ? _samples : nil
        _lastDistance = nil

        // Face: every frame while calibrating or with kNN (face-relative features). Rules only: when a hand
        // could be Teleport (fingers at the forehead) or the one-hand seal (same shape, but below the face:
        // a vertical teleport sign would otherwise read as the seal).
        let teleportish = hands.filter { GestureGeometry.isTeleportFingers($0.joints, config) }
        let sealish = hands.filter { GestureGeometry.isHandSealOneHand($0.joints, config) }
        let wantFace = alwaysDetectFace || (knn != nil && !all.isEmpty) || !(teleportish.isEmpty && sealish.isEmpty)
        var face: VNFaceObservation?
        if wantFace, (try? handler.perform([faceRequest], on: small)) != nil {
            face = faceRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        }
        var faceBox = face.map { b in
            CGRect(x: b.boundingBox.minX * aspect, y: b.boundingBox.minY, width: b.boundingBox.width * aspect, height: b.boundingBox.height)
        }
        // the teleport hand often hides the face: reuse the last face box for a moment (heads barely move)
        if let f = faceBox { recentFace = (f, Date()) }
        else if wantFace, let r = recentFace, Date().timeIntervalSince(r.at) < 1.5 { faceBox = r.box }
        _lastFeatures = GestureGeometry.features(all.map(\.joints), face: faceBox)
        if let knn, let f = _lastFeatures {
            guard !all.isEmpty else { return .none }
            let r = knn.classify(f)
            _lastDistance = r.distance
            return r.gesture
        }
        guard !hands.isEmpty else { return .none }

        func tip(_ h: (joints: HandJoints, hasWrist: Bool, indexTip: CGPoint, middleTip: CGPoint)) -> CGPoint {
            CGPoint(x: (h.indexTip.x + h.middleTip.x) / 2, y: (h.indexTip.y + h.middleTip.y) / 2)
        }
        if let face {
            let brow = (face.landmarks?.leftEyebrow?.normalizedPoints ?? []) + (face.landmarks?.rightEyebrow?.normalizedPoints ?? [])
            let box = face.boundingBox
            let browTop = brow.map { box.minY + $0.y * box.height }.max()
            let region = GestureGeometry.foreheadRegion(faceBox: box, browTopY: browTop, config)
            if teleportish.contains(where: { region.contains(tip($0)) }) { return .foreheadTwoFingers }
        }
        if hands.count == 2, GestureGeometry.isHandSeal(hands[0].joints, hands[1].joints, config) { return .handSeal }
        if let face, sealish.contains(where: { tip($0).y < face.boundingBox.midY }) { return .handSeal }
        if hands.contains(where: { GestureGeometry.isVSign($0.joints, config) }) { return .vSign }
        return .none
    }

    /// Index finger (MCP, PIP, tip) required. No wrist -> `hasWrist` false and the wrist slot holds the
    /// index MCP (features never read it; the rules skip such hands).
    private func joints(from o: VNHumanHandPoseObservation, aspect: CGFloat) -> (joints: HandJoints, hasWrist: Bool)? {
        func pt(_ n: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let r = try? o.recognizedPoint(n), r.confidence >= config.minJointConfidence else { return nil }
            return CGPoint(x: r.location.x * aspect, y: r.location.y)
        }
        func finger(_ m: VNHumanHandPoseObservation.JointName, _ p: VNHumanHandPoseObservation.JointName,
                    _ t: VNHumanHandPoseObservation.JointName) -> FingerJoints? {
            guard let a = pt(m), let b = pt(p), let c = pt(t) else { return nil }
            return FingerJoints(mcp: a, pip: b, tip: c)
        }
        guard let i = finger(.indexMCP, .indexPIP, .indexTip) else { return nil }
        let w = pt(.wrist)
        // fingers Vision can't see (interlaced in the hand seal) count as folded
        let folded = FingerJoints(mcp: i.mcp, pip: i.mcp, tip: i.mcp)
        let h = HandJoints(wrist: w ?? i.mcp, index: i, middle: finger(.middleMCP, .middlePIP, .middleTip) ?? folded,
                           ring: finger(.ringMCP, .ringPIP, .ringTip) ?? folded,
                           little: finger(.littleMCP, .littlePIP, .littleTip) ?? folded)
        return (h, w != nil)
    }

    /// vImage downscale of a BGRA buffer into a reused buffer (~analysisWidth wide).
    private func downscale(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
        guard sw > 0, sh > 0 else { return nil }
        let dw = min(sw, config.analysisWidth), dh = max(1, Int((Double(sh) * Double(dw) / Double(sw)).rounded()))
        if scaled == nil || CVPixelBufferGetWidth(scaled!) != dw || CVPixelBufferGetHeight(scaled!) != dh {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, dw, dh, kCVPixelFormatType_32BGRA, nil, &out)
            scaled = out
        }
        guard let dst = scaled else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let sb = CVPixelBufferGetBaseAddress(src), let db = CVPixelBufferGetBaseAddress(dst) else { return nil }
        var s = vImage_Buffer(data: sb, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: CVPixelBufferGetBytesPerRow(src))
        var d = vImage_Buffer(data: db, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: CVPixelBufferGetBytesPerRow(dst))
        guard vImageScale_ARGB8888(&s, &d, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        return dst
    }
}
