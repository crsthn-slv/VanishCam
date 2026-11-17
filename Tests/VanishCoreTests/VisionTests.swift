import CoreVideo
import XCTest
@testable import VanishCore

final class VisionTests: XCTestCase {
    typealias F = FingerJoints
    // Upright hand, wrist at origin, palm length 1, y up. Finger at x offset; extended => tip at y=2.2.
    func finger(x: CGFloat, ext: Bool) -> F {
        F(mcp: .init(x: x, y: 1), pip: .init(x: x, y: ext ? 1.5 : 1.3), tip: .init(x: x, y: ext ? 2.2 : 1.1))
    }
    func hand(index: Bool, middle: Bool, ring: Bool, little: Bool, spread: CGFloat = 0.5,
              at o: CGPoint = .zero) -> HandJoints {
        func s(_ f: F) -> F { F(mcp: f.mcp.off(o), pip: f.pip.off(o), tip: f.tip.off(o)) }
        var i = finger(x: -0.15, ext: index), m = finger(x: 0.05, ext: middle)
        i.tip.x -= spread / 2; m.tip.x += spread / 2
        return HandJoints(wrist: o, index: s(i), middle: s(m), ring: s(finger(x: 0.25, ext: ring)), little: s(finger(x: 0.4, ext: little)))
    }

    func testFingerExtension() {
        let w = CGPoint.zero
        XCTAssertTrue(GestureGeometry.isExtended(finger(x: 0, ext: true), wrist: w))
        XCTAssertFalse(GestureGeometry.isExtended(finger(x: 0, ext: false), wrist: w))
        XCTAssertTrue(GestureGeometry.isCurled(finger(x: 0, ext: false), wrist: w))
        XCTAssertFalse(GestureGeometry.isCurled(finger(x: 0, ext: true), wrist: w))
    }
    func testVSign() {
        XCTAssertTrue(GestureGeometry.isVSign(hand(index: true, middle: true, ring: false, little: false)))
        XCTAssertFalse(GestureGeometry.isVSign(hand(index: true, middle: true, ring: true, little: false)))
        XCTAssertFalse(GestureGeometry.isVSign(hand(index: true, middle: false, ring: false, little: false)))
        XCTAssertFalse(GestureGeometry.isVSign(hand(index: true, middle: true, ring: false, little: false, spread: 0.0)))
    }
    func testTwoFingersTogether() {
        let together = hand(index: true, middle: true, ring: false, little: false, spread: 0.0)
        XCTAssertTrue(GestureGeometry.isTwoFingersTogether(together))
        XCTAssertFalse(GestureGeometry.isTwoFingersTogether(hand(index: true, middle: true, ring: false, little: false, spread: 0.6)))
    }
    func testScaleInvariance() {
        func scaled(_ h: HandJoints, _ k: CGFloat) -> HandJoints {
            func f(_ j: F) -> F { F(mcp: j.mcp.mul(k), pip: j.pip.mul(k), tip: j.tip.mul(k)) }
            return HandJoints(wrist: h.wrist.mul(k), index: f(h.index), middle: f(h.middle), ring: f(h.ring), little: f(h.little))
        }
        let h = hand(index: true, middle: true, ring: false, little: false)
        XCTAssertTrue(GestureGeometry.isVSign(scaled(h, 0.1)))
        XCTAssertTrue(GestureGeometry.isVSign(scaled(h, 40)))
    }
    func testHandSeal() {
        let seal = { (o: CGPoint) in self.hand(index: true, middle: false, ring: false, little: false, spread: 0, at: o) }
        XCTAssertTrue(GestureGeometry.isHandSeal(seal(.zero), seal(.init(x: 0.3, y: 0))))
        XCTAssertFalse(GestureGeometry.isHandSeal(seal(.zero), seal(.init(x: 4, y: 0))))   // hands apart
        // prayer hands (all fingers up) are not the seal
        let all = { (o: CGPoint) in self.hand(index: true, middle: true, ring: true, little: true, spread: 0, at: o) }
        XCTAssertFalse(GestureGeometry.isHandSeal(all(.zero), all(.init(x: 0.3, y: 0))))
        // pointing sideways: rotate hand 90 degrees
        let s = seal(.zero), side = HandJoints(wrist: .zero, index: rot(s.index), middle: rot(s.middle), ring: rot(s.ring), little: rot(s.little))
        XCTAssertFalse(GestureGeometry.isHandSeal(side, side))
    }
    func testTeleportFingersFrontal() {
        // from the front ring/little foreshorten to ~1.7 while index/middle reach 2.2
        var h = hand(index: true, middle: true, ring: false, little: false, spread: 0.1)   // tips 0.3 apart
        h.ring = F(mcp: .init(x: 0.25, y: 1), pip: .init(x: 0.25, y: 1.4), tip: .init(x: 0.25, y: 1.7))
        XCTAssertTrue(GestureGeometry.isTeleportFingers(h))
        XCTAssertFalse(GestureGeometry.isTwoFingersTogether(h))
        XCTAssertFalse(GestureGeometry.isTeleportFingers(hand(index: true, middle: true, ring: true, little: true, spread: 0.1)))   // open hand
        XCTAssertFalse(GestureGeometry.isTeleportFingers(hand(index: true, middle: true, ring: false, little: false, spread: 0.6)))  // V
    }
    func testHandSealOneHand() {
        // clasped hands read as one: two fingers together, straight up
        let merged = hand(index: true, middle: true, ring: false, little: false, spread: 0)
        XCTAssertTrue(GestureGeometry.isHandSealOneHand(merged))
        XCTAssertFalse(GestureGeometry.isHandSealOneHand(hand(index: true, middle: true, ring: false, little: false, spread: 0.6)))   // V
        let tilted = HandJoints(wrist: .zero, index: rot(merged.index), middle: rot(merged.middle), ring: rot(merged.ring), little: rot(merged.little))
        XCTAssertFalse(GestureGeometry.isHandSealOneHand(tilted))
    }
    func rot(_ f: F) -> F { F(mcp: f.mcp.rot(), pip: f.pip.rot(), tip: f.tip.rot()) }

    func testForeheadRegion() {
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3)
        let r = GestureGeometry.foreheadRegion(faceBox: face, browTopY: 0.62)
        XCTAssertTrue(r.contains(CGPoint(x: 0.5, y: 0.75)))
        XCTAssertFalse(r.contains(CGPoint(x: 0.5, y: 0.5)))   // chin/nose area
    }

    // MARK: calibration kNN
    func testFeaturesLengthStable() {
        let h = hand(index: true, middle: true, ring: false, little: false)
        let n = GestureGeometry.featureCount
        XCTAssertEqual(GestureGeometry.features([]), Array(repeating: 0, count: n))
        XCTAssertEqual(GestureGeometry.features([h]).count, n)
        XCTAssertEqual(GestureGeometry.features([h, h, h]).count, n)
        XCTAssertEqual(GestureGeometry.features([h, h]).last, 2)
    }
    func calibrated() -> GestureSamples {
        var g = SystemRandomNumberGenerator()
        var s = GestureSamples()
        for (label, c) in [("vSign", 0.0), ("handSeal", 5.0), ("none", -5.0)] {
            for _ in 0..<30 { s.add(label: label, features: (0..<4).map { _ in c + .random(in: -0.5...0.5, using: &g) }) }
        }
        s.add(label: "vSign", features: [1, 2])   // wrong length: ignored
        return s.prepared()
    }
    func testKNNClassify() {
        let s = calibrated()
        XCTAssertEqual(s.classify([0.1, 0, -0.1, 0.2]).gesture, .vSign)
        XCTAssertEqual(s.classify([5, 5.1, 4.9, 5]).gesture, .handSeal)
        XCTAssertEqual(s.classify([-5, -5, -5, -5]).gesture, .none)
        XCTAssertEqual(s.classify([40, -40, 40, -40]).gesture, .none)   // far from everything: rejected
        XCTAssertEqual(GestureSamples().classify([0, 0, 0, 0]).gesture, .none)
    }
    func testSamplesCodable() throws {
        let s = calibrated()
        let back = try JSONDecoder().decode(GestureSamples.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.samples.count, s.samples.count)
        XCTAssertEqual(back.classify([5, 5, 5, 5]).gesture, .handSeal)
    }

    // MARK: smoke tests on a synthetic solid-colour buffer
    func solid(_ w: Int, _ h: Int) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), 0x80, CVPixelBufferGetBytesPerRow(pb!) * h)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        return pb!
    }
    func testDetectorSmoke() {
        let d = VisionGestureDetector()
        XCTAssertEqual(d.detect(in: solid(1280, 720)), .none)
        XCTAssertEqual(d.detect(in: solid(320, 240)), .none)   // size change, no upscale
    }
    func testSegmenterSmoke() throws {
        let s = VisionPersonSegmenter()
        let m = try XCTUnwrap(s.mask(for: solid(1280, 720)))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(m), kCVPixelFormatType_OneComponent8)
        XCTAssertGreaterThan(CVPixelBufferGetWidth(m), 0)   // native Vision size (4:3), covers full frame
    }
}

private extension CGPoint {
    func off(_ o: CGPoint) -> CGPoint { .init(x: x + o.x, y: y + o.y) }
    func mul(_ k: CGFloat) -> CGPoint { .init(x: x * k, y: y * k) }
    func rot() -> CGPoint { .init(x: y, y: -x) }   // 90 degrees clockwise
}
