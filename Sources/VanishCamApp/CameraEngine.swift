import AVFoundation
import AppKit
import Combine
import VanishCore

/// Owns the capture session, VanishPipeline, renderer, UYVYConverter and OBS sink (pattern from the CLI).
/// `onTick` fires once per second on the main thread.
final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, VanishSoundDelegate {
    @Published private(set) var running = false
    /// A call app is reading the OBS camera: our camera and output are on. Off between calls.
    @Published private(set) var active = false
    var onTick: (() -> Void)?
    let soundKit = SoundKit()

    private let session = AVCaptureSession()
    private let sink = ObsSink()
    private let queue = DispatchQueue(label: "vanishcam.app.cam", qos: .userInteractive)
    private var pipeline: VanishPipeline?
    private var converter: UYVYConverter?
    private var device: AVCaptureDevice?
    private var lastSync = Date.distantPast
    private var logWatcher: Process?
    private var ignoreStopsUntil = Date.distantPast

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VanishCam", isDirectory: true)
    static var plateURL: URL { support.appendingPathComponent("plate.png") }

    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified)
            .devices.filter { $0.localizedName != "OBS Virtual Camera" }
    }

    func start(settings app: AppSettings, camera: AVCaptureDevice?) throws {
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        guard !running else { return }
        guard sink.connect() else { throw NSError(domain: "VanishCam", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "OBS Virtual Camera not found — start it once in OBS, then quit OBS."]) }
        let renderer = try EffectRenderer()
        var s = VanishPipeline.Settings(plateURL: Self.plateURL)
        s.holdSeconds = app.holdSeconds
        s.calibrationSeconds = app.calibrationSeconds
        s.outputWidth = app.outputWidth
        s.outputHeight = app.outputHeight
        let p = try VanishPipeline(settings: s, renderer: renderer,
                                   detector: VisionGestureDetector(), segmenter: VisionPersonSegmenter())
        p.soundDelegate = self
        pipeline = p
        converter = try UYVYConverter(device: renderer.device, queue: renderer.commandQueue)
        apply(settings: app)

        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.sessionPreset = app.outputHeight >= 1080 ? .hd1920x1080 : .hd1280x720
        if let camera, let input = try? AVCaptureDeviceInput(device: camera) { session.addInput(input) }
        device = camera
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(out)
        session.commitConfiguration()
        sink.pause()   // camera + output stay off until a call app opens the OBS camera
        running = true
        watchForCalls()
    }

    /// In a call = another app reads the OBS camera. While our output is paused, the device's
    /// "running somewhere" flag shows exactly that (polled 1 Hz). While it runs, the flag includes us,
    /// so we wait for the OBS extension to log "stop streaming" (a reader left), then pause our output
    /// for 60 ms and check the flag. (Pausing shows OBS's placeholder for a frame: only done then.)
    private func watchForCalls() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !active, sink.othersReading { setActive(true) }
            onTick?()
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate",
                       #"process CONTAINS "camera-extension" AND eventMessage CONTAINS "stop streaming""#]
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard String(decoding: h.availableData, as: UTF8.self).contains("stop streaming") else { return }
            DispatchQueue.main.async { self?.readerLeft() }
        }
        try? p.run()
        logWatcher = p
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.logWatcher?.terminate()
        }
    }

    private func readerLeft() {
        guard active, Date() > ignoreStopsUntil else { return }
        ignoreStopsUntil = Date() + 2   // our own pause logs "stop streaming" too
        sink.pause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [self] in
            if sink.othersReading { sink.resume() } else { setActive(false) }
        }
    }

    private func setActive(_ on: Bool) {
        active = on
        vanishLog(on ? "call started: camera on" : "call ended: camera off")
        if on {
            sink.resume()
            queue.async { [self] in pipeline?.reset(); session.startRunning(); syncBackgroundEffect() }
        } else {
            ignoreStopsUntil = Date() + 2
            sink.pause()
            queue.async { [session] in session.stopRunning() }
        }
    }

    func toggle() { pipeline?.toggle() }
    func recapture() { pipeline?.recapture() }
    var phaseName: String { pipeline?.phaseName ?? "stopped" }
    var needsRoomCapture: Bool { pipeline?.needsRoomCapture ?? false }

    /// Hot-apply resolution / hold time / calibration / sound without restarting the session.
    func apply(settings app: AppSettings) {
        if let p = pipeline {
            p.settings.holdSeconds = app.holdSeconds
            p.settings.enabled = app.enabledEffects
            p.settings.calibrationSeconds = app.calibrationSeconds
            p.settings.outputWidth = app.outputWidth
            p.settings.outputHeight = app.outputHeight
        }
        soundKit.enabled = app.soundEnabled
        soundKit.volume = Float(app.soundVolume)
    }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb),
              let out = pipeline?.process(pb), let uyvy = converter?.convert(out) else { return }
        sink.send(uyvy)
        if Date().timeIntervalSince(lastSync) >= 1 { lastSync = Date(); syncBackgroundEffect() }
    }

    /// macOS camera "Background" effect (Control Center): fill behind the person from the live
    /// background instead of the saved room. Also run before the first frame -> no mode switch mid-stream.
    private func syncBackgroundEffect() {
        guard #available(macOS 15.0, *), let d = device, let p = pipeline else { return }
        if p.settings.liveBackground != d.isBackgroundReplacementActive {
            p.settings.liveBackground = d.isBackgroundReplacementActive
            vanishLog("macOS background effect: \(d.isBackgroundReplacementActive ? "on" : "off")")
        }
        if d.isBackgroundReplacementActive { p.settings.backgroundImageURL = Self.selectedBackgroundURL() }
    }

    // sounds: substitution "poof" on vanish only; teleport both ways
    /// The image macOS Video Effects uses as this app's background. Private AVFoundation function
    /// (AVControlCenterVideoEffectsModuleGetBackgroundReplacementURL(bundleID) -> NSURL); nil if missing.
    private static let getBackgroundURL: (@convention(c) (NSString) -> Unmanaged<NSURL>?)? = {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AVControlCenterVideoEffectsModuleGetBackgroundReplacementURL")
            .map { unsafeBitCast($0, to: (@convention(c) (NSString) -> Unmanaged<NSURL>?).self) }
    }()
    static func selectedBackgroundURL() -> URL? {
        guard let f = getBackgroundURL, let id = Bundle.main.bundleIdentifier else { return nil }
        return f(id as NSString)?.takeUnretainedValue() as URL?
    }

    func vanishDidStart() {
        switch pipeline?.effectKind { case .substitution: soundKit.play(asset: "poof.mp3")
        case .teleport: soundKit.play(asset: "teleport.wav"); default: break }
    }
    func reappearDidStart() {
        switch pipeline?.effectKind { case .substitution: break
        case .teleport: soundKit.play(asset: "teleport.wav"); default: break }
    }
}
