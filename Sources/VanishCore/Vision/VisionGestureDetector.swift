import Accelerate
import CoreVideo
import Foundation
import Vision
import VideoToolbox

/// Apple Vision gesture detector. Call from one background queue (internally locked anyway).
/// Priority: foreheadTwoFingers > handSeal > vSign.
public final class VisionGestureDetector: GestureDetecting {
    public var config: GestureConfig
    private let lock = NSLock()
    private let handler = VNSequenceRequestHandler()
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private var scaled: CVPixelBuffer?

    public init(config: GestureConfig = .init()) {
        self.config = config
        handRequest.maximumHandCount = 2
    }

    public var debugEnabled = false
    public private(set) var lastDebug: GestureDebugFrame? {
        get { lock.lock(); defer { lock.unlock() }; return debugFrame }
        set { debugFrame = newValue }
    }
    private var debugFrame: GestureDebugFrame?

    public func detect(in pixelBuffer: CVPixelBuffer) -> Gesture {
        lock.lock(); defer { lock.unlock() }
        guard let small = downscale(pixelBuffer) else { return .none }
        do { try handler.perform([handRequest], on: small) } catch { return .none }
        let aspect = CGFloat(CVPixelBufferGetWidth(small)) / CGFloat(CVPixelBufferGetHeight(small))
        var hands: [HandSample] = [], dbgFingers: [[[CGPoint]]] = [], dropped: [String] = []
        for o in handRequest.results ?? [] {
            let p = { (n: VNHumanHandPoseObservation.JointName) -> CGPoint? in
                guard let r = try? o.recognizedPoint(n), r.confidence >= self.config.minJointConfidence else { return nil }; return r.location }
            guard let h = joints(from: o, aspect: aspect) else {
                if debugEnabled {
                    let all = (try? o.recognizedPoints(.all)) ?? [:]
                    let low = all.filter { $0.value.confidence < config.minJointConfidence }.map { "\($0.key.rawValue.rawValue) \(String(format: "%.2f", $0.value.confidence))" }.sorted()
                    dropped.append("dropped (min \(config.minJointConfidence), wrist \(config.minWristConfidence)): " + low.joined(separator: ", "))
                }
                continue
            }
            // normalized tips: the face box is normalized too
            let (a, b) = (p(.indexTip) ?? .zero, p(.middleTip) ?? .zero)
            hands.append(HandSample(joints: h, tip: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
            if debugEnabled {
                let names: [[VNHumanHandPoseObservation.JointName]] = [[.indexMCP, .indexPIP, .indexTip], [.middleMCP, .middlePIP, .middleTip],
                                                                       [.ringMCP, .ringPIP, .ringTip], [.littleMCP, .littlePIP, .littleTip]]
                dbgFingers.append(names.map { ([p(.wrist)] + $0.map(p)).compactMap { $0 } })
            }
        }
        // Face only when a hand could be Teleport (fingers at the forehead) or the interlaced seal (upright index); always in debug.
        let needFace = debugEnabled || hands.contains { GestureGeometry.isTeleportFingers($0.joints, config) || GestureGeometry.tiltFromUp($0.joints) <= config.sealBlobMaxTiltDeg }
        var face: FaceSample?
        if needFace, (try? handler.perform([faceRequest], on: small)) != nil,
           let f = faceRequest.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) {
            let brow = (f.landmarks?.leftEyebrow?.normalizedPoints ?? []) + (f.landmarks?.rightEyebrow?.normalizedPoints ?? [])
            face = FaceSample(box: f.boundingBox, browTopY: brow.map { f.boundingBox.minY + $0.y * f.boundingBox.height }.max())
        }
        let g = GestureGeometry.classify(hands: hands, face: face, config)
        if debugEnabled {
            let region = face?.forehead(config)
            var img: CGImage?
            VTCreateCGImageFromCVPixelBuffer(small, options: nil, imageOut: &img)
            debugFrame = GestureDebugFrame(
                image: img,
                hands: zip(hands, dbgFingers).map { h, f in
                    .init(fingers: f, readouts: GestureGeometry.readouts(h.joints, config), inForehead: region?.contains(h.tip) ?? false) },
                sample: hands, face: face, forehead: region,
                seal: hands.count == 2 ? GestureGeometry.sealReadout(hands[0].joints, hands[1].joints, config)
                    : hands.count == 1 ? face.map { GestureReadout(gesture: "Interlaced seal, merged hand (substitution)", checks: GestureGeometry.sealBlobChecks(hands[0], $0, config)) } : nil, dropped: dropped, gesture: g)
        } else { debugFrame = nil }
        return g
    }

    private func joints(from o: VNHumanHandPoseObservation, aspect: CGFloat) -> HandJoints? {
        func pt(_ n: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let r = try? o.recognizedPoint(n), r.confidence >= (n == .wrist ? config.minWristConfidence : config.minJointConfidence) else { return nil }
            return CGPoint(x: r.location.x * aspect, y: r.location.y)
        }
        func finger(_ m: VNHumanHandPoseObservation.JointName, _ p: VNHumanHandPoseObservation.JointName,
                    _ t: VNHumanHandPoseObservation.JointName) -> FingerJoints? {
            guard let a = pt(m), let b = pt(p), let c = pt(t) else { return nil }
            return FingerJoints(mcp: a, pip: b, tip: c)
        }
        guard let w = pt(.wrist), let i = finger(.indexMCP, .indexPIP, .indexTip) else { return nil }
        // fingers Vision can't see (interlaced in the hand seal) count as folded
        let folded = FingerJoints(mcp: i.mcp, pip: i.mcp, tip: i.mcp)
        return HandJoints(wrist: w, index: i, middle: finger(.middleMCP, .middlePIP, .middleTip) ?? folded,
                          ring: finger(.ringMCP, .ringPIP, .ringTip) ?? folded,
                          little: finger(.littleMCP, .littlePIP, .littleTip) ?? folded)
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
