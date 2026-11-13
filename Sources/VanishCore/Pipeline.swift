import Foundation
import ImageIO
import CoreVideo
import simd

/// Notified at transition points; called on the capture queue.
public protocol VanishSoundDelegate: AnyObject {
    func vanishDidStart()
    func reappearDidStart()
}

/// Camera frame in -> processed frame out. Owns the vanish state machine.
/// Call `process` from the capture queue. Gesture detection runs on its own queue at ~`gestureHz`.
public final class VanishPipeline {
    public struct Settings {
        public var holdSeconds = 0.5          // how long the gesture must be held
        public var calibrationSeconds = 4.0   // time to step out of frame when no saved plate exists
        public var gestureHz = 10.0
        public var effect: EffectKind = .dissolve   // starting effect (manual toggle uses the last one used)
        /// Effects whose gesture is listened for; each gesture triggers its own effect.
        public var enabled: Set<EffectKind> = Set(EffectKind.allCases)
        public var outputWidth = 1920, outputHeight = 1080   // OBS camera extension advertises 1080p
        public var plateURL: URL
        public var debug = false
        /// macOS camera "Background" effect is on: the background is synthetic, so fill the area behind
        /// the person from the visible background each frame instead of using the saved room plate.
        public var liveBackground = false
        /// The macOS background image selected for this app (nil = solid colour / unknown).
        public var backgroundImageURL: URL?
        public init(plateURL: URL) { self.plateURL = plateURL }
    }

    enum Phase { case calibrating(start: Date), live, vanishing(start: Date), gone(since: Date), returning(start: Date) }

    public var settings: Settings
    public weak var soundDelegate: VanishSoundDelegate?
    private let renderer: EffectRenderer
    private let detector: GestureDetecting
    private let segmenter: PersonSegmenting
    private let plate = BackgroundPlate()
    private let fillBuffer = PixelBufferIO.make(width: 64, height: 36)!
    private var bgOut: CVPixelBuffer?, cleanFrame: CVPixelBuffer?, noImage: CVPixelBuffer?
    private var bgImage: CVPixelBuffer?, bgImageURL: URL?, bgAligning = false, bgAligned: (URL, CVPixelBuffer)?
    private let alignQueue = DispatchQueue(label: "vanishcam.align", qos: .utility)
    private var active: Effect
    private var phase: Phase = .live
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)

    private let lock = NSLock()
    private var latestGesture: Gesture = .none
    private var detecting = false
    private var lastDetect = Date.distantPast
    private var holdStart = Date.distantPast
    private var heldGesture: Gesture = .none
    private var lastSeen = Date.distantPast
    private var armed = true
    private var pendingToggle = false
    private var pendingRecapture = false
    private let detectQueue = DispatchQueue(label: "vanishcam.detect", qos: .userInitiated)

    public init(settings: Settings, renderer: EffectRenderer, detector: GestureDetecting, segmenter: PersonSegmenting) throws {
        self.settings = settings
        self.renderer = renderer
        self.detector = detector
        self.segmenter = segmenter
        guard let e = try renderer.effect(settings.effect) else { throw EffectError.missingFunction("\(settings.effect)") }
        active = e
    }

    /// Effect of the current / last vanish (call from the capture queue).
    public var effectKind: EffectKind { active.kind }
    /// Back to live, e.g. at the start of a new call (call from the capture queue).
    public func reset() { phase = .live; armed = false }

    /// Manual controls (thread-safe): same as the gesture.
    public func toggle() { lock.lock(); pendingToggle = true; lock.unlock() }
    public func recapture() { lock.lock(); pendingRecapture = true; lock.unlock() }

    public func process(_ frame: CVPixelBuffer) -> CVPixelBuffer? {
        let now = Date()
        let w = settings.outputWidth, h = settings.outputHeight
        if firstFrame { firstFrame = false; startup(w, h, now) }
        guard let out = nextOutput(w, h) else { return nil }
        let camera = frame                     // detection/segmentation use the native-size frame
        let frame = scaled(camera, w, h) ?? camera   // everything visual runs at output size
        handleControls(now, w, h)
        scheduleDetection(camera, now)

        switch phase {
        case .calibrating where settings.liveBackground:
            phase = .live
            renderer.passThrough(frame: frame, into: out)
        case .calibrating(let start):
            // only count/average frames where the person is absent; presence pushes the deadline back
            let absent = Self.personFraction(segmenter.mask(for: camera)) < 0.08
            if absent, now.timeIntervalSince(start) >= settings.calibrationSeconds, plate.add(camera) {
                try? plate.save(to: settings.plateURL)
                log("background captured and saved: \(settings.plateURL.path)")
                phase = .live
            } else if !absent {
                plate.reset(); phase = .calibrating(start: now)   // came back too early: start over
            }
            renderer.passThrough(frame: frame, into: out)
        case .live:
            renderer.passThrough(frame: frame, into: out)

        case .vanishing(let start):
            let p = Float(now.timeIntervalSince(start) / active.duration)
            if p >= 1 { phase = .gone(since: now) }
            let m = segmenter.mask(for: camera); lastMaskFraction = Self.personFraction(m)
            animate(frame: frame, mask: m, progress: min(p, 1), elapsed: now.timeIntervalSince(start), reverse: false, into: out)
        case .gone(let since):
            if let pb = liveBackground(frame, segmenter.mask(for: camera), imageWeight: 1)?.plate ?? plate.pixelBuffer {
                let t = Float(now.timeIntervalSince(since))
                renderer.renderSteady(effect: active, frame: frame, plate: pb, time: t, into: out)
                overlay(out, mask: nil, time: t, reverse: false, steady: true)
            } else { renderer.passThrough(frame: frame, into: out) }
        case .returning(let start):
            let p = Float(now.timeIntervalSince(start) / active.returnDuration)
            if p >= 1 { phase = .live; renderer.passThrough(frame: frame, into: out) }
            else {
                let m = segmenter.mask(for: camera); lastMaskFraction = Self.personFraction(m)
                animate(frame: frame, mask: m, progress: p, elapsed: now.timeIntervalSince(start), reverse: true, into: out)
            }
        }
        return out
    }

    /// fraction of the mask that is person (mask is OneComponent8, any size)
    /// One animated frame. `progress` is elapsed/duration (0...1); the effect flips it when `reverse` is true.
    private func animate(frame: CVPixelBuffer, mask m: CVPixelBuffer?, progress p: Float, elapsed: Double,
                         reverse: Bool, into out: CVPixelBuffer) {
        var bg = plate.pixelBuffer, frame = frame
        // whole frame eases into the background over the animation, so "gone" is one image (no seams)
        let weight = Float(reverse ? 1 - p : p)
        active.exposure = .init(repeating: 1)
        if let lb = liveBackground(frame, m, imageWeight: weight * weight * (3 - 2 * weight)) { bg = lb.plate; frame = lb.clean }
        renderer.render(effect: active, frame: frame, plate: bg, mask: m,
                        progress: p, time: Float(elapsed), reverse: reverse, into: out)
        overlay(out, mask: m, time: Float(elapsed), reverse: reverse, steady: false)
    }

    /// CPU drawing pass of the effect (sprites, smoke, lines) on top of the GPU result, y-down.
    private func overlay(_ out: CVPixelBuffer, mask: CVPixelBuffer?, time: Float, reverse: Bool, steady: Bool) {
        guard active.hasOverlay else { return }
        let w = CVPixelBufferGetWidth(out), h = CVPixelBufferGetHeight(out)
        try? PixelBufferIO.withContext(out) { ctx in
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            active.drawOverlay(in: ctx, width: w, height: h, mask: mask, time: time, reverse: reverse, steady: steady)
        }
    }

    /// Background behind the person + the frame with the halo around the person replaced by it.
    /// macOS Background on: the exact image macOS uses (solid colours: coarse fill of the visible background).
    /// Off (real room): the saved plate, corrected per region to the camera's current exposure.
    private var imageGain = SIMD3<Float>(repeating: 1), roomGain = SIMD3<Float>(repeating: 1)
    private func liveBackground(_ frame: CVPixelBuffer, _ mask: CVPixelBuffer?, imageWeight: Float) -> (plate: CVPixelBuffer, clean: CVPixelBuffer)? {
        guard let mask else { return nil }
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        if bgOut.map({ CVPixelBufferGetWidth($0) != w || CVPixelBufferGetHeight($0) != h }) ?? true {
            bgOut = PixelBufferIO.make(width: w, height: h); cleanFrame = PixelBufferIO.make(width: w, height: h)
            noImage = PixelBufferIO.make(width: w, height: h)
            if let n = noImage { PixelBufferIO.fill(n, r: 0, g: 0, b: 0, a: 0) }
            bgImageURL = nil
        }
        guard let out = bgOut, let clean = cleanFrame else { return nil }
        if !settings.liveBackground {
            guard let room = plate.pixelBuffer else { return nil }
            // one gain for the whole plate (camera auto-exposure), smoothed: no spatial blotches
            roomGain = roomGain * 0.8 + Self.exposureGain(frame: frame, plate: room, mask: mask) * 0.2
            guard renderer.backgroundMemory(frame: frame, previous: room, mask: mask, fill: fillBuffer, memory: out, clean: clean,
                                            gain: roomGain, imageWeight: imageWeight, dilate: 1.4,
                                            ringFollowsWeight: true) else { return nil }
            return (out, clean)
        }
        let url = settings.backgroundImageURL
        if url != bgImageURL {
            bgImageURL = url; bgAligning = false; imageGain = .one
            bgImage = url.flatMap { try? PixelBufferIO.loadImage(at: $0, width: w, height: h) }
            log("macOS background image: \(url?.lastPathComponent ?? "none (colour)")")
        }
        // align once per image (mirror/scale/offset of macOS's placement), off the capture queue
        lock.lock(); let aligned = bgAligned; bgAligned = nil; lock.unlock()
        if let (u, pb) = aligned, u == url { bgImage = pb }
        if let img = bgImage, !bgAligning, let url, let f = PixelBufferIO.make(width: w, height: h),
           renderer.passThrough(frame: frame, into: f) {   // private copy: the camera buffer gets recycled
            bgAligning = true
            alignQueue.async { [self] in
                let t0 = Date()
                let fit = BackgroundAlign.fit(frame: f, image: img, mask: mask)
                guard fit.cost.isFinite, let pb = try? PixelBufferIO.loadImage(at: url, width: w, height: h, mirrored: fit.mirrored,
                        scale: fit.scale, offset: CGPoint(x: fit.dx, y: fit.dy)) else { return }
                log(String(format: "background aligned in %.2f s: mirrored %@ scale %.3f offset %.3f,%.3f cost %.1f",
                           Date().timeIntervalSince(t0), "\(fit.mirrored)", fit.scale, fit.dx, fit.dy, fit.cost))
                lock.lock(); bgAligned = (url, pb); lock.unlock()
            }
        }
        guard let prev = bgImage ?? noImage else { return nil }
        if let img = bgImage {   // macOS dims/tints the image when compositing: match it (median ratio, smoothed)
            imageGain = imageGain * 0.7 + Self.exposureGain(frame: frame, plate: img, mask: mask) * 0.3
        } else { Self.fillBackground(frame: frame, mask: mask, into: fillBuffer) }
        guard renderer.backgroundMemory(frame: frame, previous: prev, mask: mask, fill: fillBuffer,
                                        memory: out, clean: clean, gain: imageGain, imageWeight: imageWeight) else { return nil }
        return (out, clean)
    }

    /// Mean |frame - image| over visible (non-person) pixels, sparse grid; nil if too few.
    static func backgroundDiff(frame: CVPixelBuffer, image: CVPixelBuffer, mask: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(frame, .readOnly); CVPixelBufferLockBaseAddress(image, .readOnly)
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly); CVPixelBufferUnlockBaseAddress(image, .readOnly)
                CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let fb = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let ib = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let kb = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self)
        let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
        let fr = CVPixelBufferGetBytesPerRow(frame), ir = CVPixelBufferGetBytesPerRow(image), kr = CVPixelBufferGetBytesPerRow(mask)
        let kw = CVPixelBufferGetWidth(mask), kh = CVPixelBufferGetHeight(mask)
        var diff = 0, n = 0
        for y in stride(from: 0, to: h, by: 16) { for x in stride(from: 0, to: w, by: 16) {
            guard kb[(y * kh / h) * kr + x * kw / w] < 8 else { continue }
            let fo = y * fr + x * 4, io = y * ir + x * 4
            for c in 0..<3 { diff += abs(Int(fb[fo + c]) - Int(ib[io + c])) }
            n += 3
        } }
        return n > 600 ? diff / n : nil
    }

    static func fillBackground(frame: CVPixelBuffer, mask: CVPixelBuffer?, into out: CVPixelBuffer) {
        let gw = CVPixelBufferGetWidth(out), gh = CVPixelBufferGetHeight(out)
        var sum = [SIMD3<Float>](repeating: .zero, count: gw * gh), n = [Float](repeating: 0, count: gw * gh)
        CVPixelBufferLockBaseAddress(frame, .readOnly); defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        if let mask { CVPixelBufferLockBaseAddress(mask, .readOnly) }
        defer { if let mask { CVPixelBufferUnlockBaseAddress(mask, .readOnly) } }
        let fb = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let fw = CVPixelBufferGetWidth(frame), fh = CVPixelBufferGetHeight(frame), fr = CVPixelBufferGetBytesPerRow(frame)
        let mb = mask.flatMap { CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self) }
        let mw = mask.map(CVPixelBufferGetWidth) ?? 1, mh = mask.map(CVPixelBufferGetHeight) ?? 1
        let mr = mask.map(CVPixelBufferGetBytesPerRow) ?? 0
        for y in stride(from: 0, to: fh, by: 4) {
            for x in stride(from: 0, to: fw, by: 4) {
                if let mb {   // person or its halo: check the point and a ring ~4% of the frame around it
                    let mx = x * mw / fw, my = y * mh / fh, rx = mw / 25, ry = mh / 25
                    if [(0, 0), (-rx, 0), (rx, 0), (0, -ry), (0, ry)].contains(where: { d in
                        let xx = min(max(mx + d.0, 0), mw - 1), yy = min(max(my + d.1, 0), mh - 1)
                        return mb[yy * mr + xx] > 8 }) { continue }
                }
                let o = y * fr + x * 4, c = (y * gh / fh) * gw + x * gw / fw
                sum[c] += SIMD3(Float(fb[o]), Float(fb[o + 1]), Float(fb[o + 2])); n[c] += 1
            }
        }
        var col = (0..<sum.count).map { n[$0] > 0 ? sum[$0] / n[$0] : SIMD3<Float>(-1, -1, -1) }
        var holes = col.contains { $0.x < 0 }
        while holes {   // grow known cells into holes, one ring per pass
            holes = false
            var next = col
            for y in 0..<gh { for x in 0..<gw where col[y * gw + x].x < 0 {
                var acc = SIMD3<Float>.zero, k: Float = 0
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, xx < gw, yy >= 0, yy < gh, col[yy * gw + xx].x >= 0 { acc += col[yy * gw + xx]; k += 1 }
                }
                if k > 0 { next[y * gw + x] = acc / k } else { holes = true }
            } }
            if next.allSatisfy({ $0.x < 0 }) { next = next.map { _ in SIMD3(128, 128, 128) } }   // nothing visible
            col = next
        }
        CVPixelBufferLockBaseAddress(out, []); defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let ob = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self), orr = CVPixelBufferGetBytesPerRow(out)
        for y in 0..<gh { for x in 0..<gw {
            let c = col[y * gw + x], o = y * orr + x * 4
            ob[o] = UInt8(c.x); ob[o + 1] = UInt8(c.y); ob[o + 2] = UInt8(c.z); ob[o + 3] = 255
        } }
    }

    /// Per-channel gain bringing the plate to the live exposure, measured as the MEDIAN of pixels
    /// away from the person (mask-gated, ::8 grid), like the original. Camera auto-exposure drifts.
    static func exposureGain(frame: CVPixelBuffer, plate pb: CVPixelBuffer, mask m: CVPixelBuffer?) -> SIMD3<Float> {
        CVPixelBufferLockBaseAddress(frame, .readOnly); CVPixelBufferLockBaseAddress(pb, .readOnly)
        let mLocked = m != nil
        if mLocked { CVPixelBufferLockBaseAddress(m!, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(frame, .readOnly); CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            if mLocked { CVPixelBufferUnlockBaseAddress(m!, .readOnly) }
        }
        guard let fb = CVPixelBufferGetBaseAddress(frame), let pbb = CVPixelBufferGetBaseAddress(pb) else { return .init(repeating: 1) }
        let fw = CVPixelBufferGetWidth(frame), fh = CVPixelBufferGetHeight(frame)
        let fbr = CVPixelBufferGetBytesPerRow(frame), pbr = CVPixelBufferGetBytesPerRow(pb)
        let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb)   // plate may differ in size from the frame
        let mw = m.map { CVPixelBufferGetWidth($0) } ?? 0, mh = m.map { CVPixelBufferGetHeight($0) } ?? 0
        let mbr = m.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let mBase: UnsafeMutablePointer<UInt8>? = m.flatMap { CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self) }
        let fp = fb.assumingMemoryBound(to: UInt8.self), pp = pbb.assumingMemoryBound(to: UInt8.self)
        var hf = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var hp = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var kept = 0
        for y in stride(from: 0, to: fh, by: 8) {
            for x in stride(from: 0, to: fw, by: 8) {
                if let mb = mBase, mb[(y * mh / fh) * mbr + (x * mw / fw)] > 13 { continue }   // on/near the person
                let fo = y * fbr + x * 4, po = (y * ph / fh) * pbr + (x * pw / fw) * 4
                hf[0][Int(fp[fo])] += 1; hf[1][Int(fp[fo + 1])] += 1; hf[2][Int(fp[fo + 2])] += 1
                hp[0][Int(pp[po])] += 1; hp[1][Int(pp[po + 1])] += 1; hp[2][Int(pp[po + 2])] += 1
                kept += 1
            }
        }
        guard kept >= 32 else { return .init(repeating: 1) }
        func median(_ h: [Int], _ total: Int) -> Float {
            var acc = 0
            for v in 0..<256 { acc += h[v]; if acc * 2 >= total { return Float(v) } }
            return 255
        }
        var gain = SIMD3<Float>(0, 0, 0)
        for i in 0..<3 {
            let live = median(hf[i], kept), fixed = max(median(hp[i], kept), 1)
            gain[i] = min(max(live / fixed, 0.5), 2.0)
        }
        return gain
    }


    static func personFraction(_ mask: CVPixelBuffer?) -> Float {
        guard let mask, CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else { return 0 }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(mask), h = CVPixelBufferGetHeight(mask), w = CVPixelBufferGetWidth(mask)
        var hit = 0, total = 0
        for y in stride(from: 0, to: h, by: 2) {
            let row = base + y * bpr
            for x in stride(from: 0, to: w, by: 2) { total += 1; if row[x] > 128 { hit += 1 } }
        }
        return total == 0 ? 0 : Float(hit) / Float(total)
    }

    // MARK: internals
    private var firstFrame = true
    private func startup(_ w: Int, _ h: Int, _ now: Date) {
        if (try? plate.load(from: settings.plateURL, width: w, height: h)) != nil, plate.isComplete {
            log("loaded saved background")
            phase = .live
        } else {
            log("no saved room background: use Recapture Background")   // calibration is manual only
            phase = .live
        }
    }

    private func handleControls(_ now: Date, _ w: Int, _ h: Int) {
        lock.lock()
        let t = pendingToggle, r = pendingRecapture, g = latestGesture
        pendingToggle = false; pendingRecapture = false
        lock.unlock()
        if r { plate.reset(); phase = .calibrating(start: now); log("recapturing: step out of frame"); return }
        var trigger = t
        // Vision drops the gesture for single frames: a hold only breaks after 0.4 s without it
        if g != .none {
            if g != heldGesture { heldGesture = g; holdStart = now; armed = true }
            lastSeen = now
        } else if now.timeIntervalSince(lastSeen) > 0.4 { heldGesture = .none; armed = true }
        // every enabled gesture is live: it vanishes with its own effect; any of them brings you back
        // with the effect you vanished with. the seal fires at once, teleport needs a 1 s hold
        if armed, let k = [Gesture.vSign: EffectKind.dissolve, .handSeal: .substitution, .foreheadTwoFingers: .teleport][heldGesture],
           settings.enabled.contains(k), now.timeIntervalSince(holdStart) >= ([.substitution: 0.0, .teleport: 1.0][k] ?? settings.holdSeconds) {
            trigger = true; armed = false
            if case .live = phase, k != active.kind, let e = try? renderer.effect(k) { active = e }
        }
        guard trigger else { return }
        switch phase {
        case .live where needsRoomCapture: log("no room captured yet: use Recapture Background")
        case .live: phase = .vanishing(start: now); log("vanish"); soundDelegate?.vanishDidStart()
        case .gone: phase = .returning(start: now); log("reappear"); soundDelegate?.reappearDidStart()
        default: break
        }
    }

    /// Real-room mode needs a captured room (Recapture Background) to vanish.
    public var needsRoomCapture: Bool { !settings.liveBackground && plate.pixelBuffer == nil }

    public var phaseName: String {
        lock.lock(); defer { lock.unlock() }
        switch phase { case .calibrating: return "calibrating"; case .live: return "live"; case .vanishing: return "vanishing"; case .gone: return "gone"; case .returning: return "returning" }
    }
    public private(set) var lastMaskFraction: Float = 0

    private func scheduleDetection(_ frame: CVPixelBuffer, _ now: Date) {
        lock.lock()
        let go = !detecting && now.timeIntervalSince(lastDetect) >= 1 / settings.gestureHz
        if go { detecting = true; lastDetect = now }
        lock.unlock()
        guard go else { return }
        detectQueue.async { [self] in
            let g = detector.detect(in: frame)
            lock.lock(); latestGesture = g; detecting = false; lock.unlock()
            if settings.debug { log("gesture: \(g)") }
        }
    }

    private var scalePool: CVPixelBufferPool?
    private func scaled(_ src: CVPixelBuffer, _ w: Int, _ h: Int) -> CVPixelBuffer? {
        if CVPixelBufferGetWidth(src) == w, CVPixelBufferGetHeight(src) == h { return src }
        if scalePool == nil {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &scalePool)
        }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, scalePool!, &pb)
        guard let dst = pb, renderer.passThrough(frame: src, into: dst) else { return nil }
        return dst
    }

    private func nextOutput(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool); poolSize = (w, h)
        }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
        return pb
    }
    private func log(_ s: String) { vanishLog(s) }
}

/// stdout + ~/Library/Logs/VanishCam.log (the menu-bar app has no console).
public func vanishLog(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    print("[vanishcam] \(s)")
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/VanishCam.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: url) }
}
