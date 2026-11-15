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
    func rot(_ f: F) -> F { F(mcp: f.mcp.rot(), pip: f.pip.rot(), tip: f.tip.rot()) }

    func testForeheadRegion() {
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3)
        let r = GestureGeometry.foreheadRegion(faceBox: face, browTopY: 0.62)
        XCTAssertTrue(r.contains(CGPoint(x: 0.5, y: 0.75)))
        XCTAssertFalse(r.contains(CGPoint(x: 0.5, y: 0.5)))   // chin/nose area
    }

    // MARK: debug readouts + fixtures
    func testReadoutsAgreeWithRules() {
        for (i, m, g, l, sp) in [(true, true, false, false, 0.5), (true, true, false, false, 0.0), (true, true, true, false, 0.5),
                                 (true, false, false, false, 0.0), (true, true, true, true, 0.1)] as [(Bool, Bool, Bool, Bool, CGFloat)] {
            let h = hand(index: i, middle: m, ring: g, little: l, spread: sp)
            let r = GestureGeometry.readouts(h)
            XCTAssertEqual(r[0].pass, GestureGeometry.isVSign(h))
            XCTAssertEqual(r[1].pass, GestureGeometry.isTeleportFingers(h))
        }
        let s = { (o: CGPoint) in self.hand(index: true, middle: false, ring: false, little: false, spread: 0, at: o) }
        XCTAssertTrue(GestureGeometry.sealReadout(s(.zero), s(.init(x: 0.3, y: 0))).pass)
        XCTAssertFalse(GestureGeometry.sealReadout(s(.zero), s(.init(x: 4, y: 0))).pass)
    }
    func testClassify() {
        let v = HandSample(joints: hand(index: true, middle: true, ring: false, little: false), tip: .init(x: 0.5, y: 0.2))
        XCTAssertEqual(GestureGeometry.classify(hands: [v], face: nil), .vSign)
        XCTAssertEqual(GestureGeometry.classify(hands: [], face: nil), .none)
        // two fingers together at the forehead -> teleport; upright below the forehead = interlaced seal (merged hand); tilted = nothing
        let t = HandSample(joints: hand(index: true, middle: true, ring: false, little: false, spread: 0), tip: .init(x: 0.5, y: 0.75))
        let face = FaceSample(box: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.3), browTopY: 0.62)
        XCTAssertEqual(GestureGeometry.classify(hands: [t], face: face), .foreheadTwoFingers)
        var low = t; low.tip = .init(x: 0.5, y: 0.3)
        XCTAssertEqual(GestureGeometry.classify(hands: [low], face: face), .handSeal)
        let j = low.joints
        let side = HandSample(joints: HandJoints(wrist: j.wrist, index: rot(j.index), middle: rot(j.middle), ring: rot(j.ring), little: rot(j.little)), tip: low.tip)
        XCTAssertEqual(GestureGeometry.classify(hands: [side], face: face), .none)
        // two hands clasped -> seal
        let seal = { (o: CGPoint) in HandSample(joints: self.hand(index: true, middle: false, ring: false, little: false, spread: 0, at: o), tip: .zero) }
        XCTAssertEqual(GestureGeometry.classify(hands: [seal(.zero), seal(.init(x: 0.3, y: 0))], face: nil), .handSeal)
    }
    /// Replays every JSON saved by the debug window's "Record frame" button (drop them in Fixtures/).
    func testRecordedFixtures() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            let fx = try JSONDecoder().decode(GestureFixture.self, from: Data(contentsOf: f))
            XCTAssertEqual(GestureGeometry.classify(hands: fx.hands, face: fx.face), fx.expected, f.lastPathComponent)
        }
    }
    func testFixtureRoundTrip() throws {
        let fx = GestureFixture(expected: .vSign, hands: [HandSample(joints: hand(index: true, middle: true, ring: false, little: false), tip: .init(x: 0.5, y: 0.2))], face: nil)
        let back = try JSONDecoder().decode(GestureFixture.self, from: JSONEncoder().encode(fx))
        XCTAssertEqual(GestureGeometry.classify(hands: back.hands, face: back.face), .vSign)
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
