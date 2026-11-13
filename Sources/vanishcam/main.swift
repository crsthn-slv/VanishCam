import Foundation
import AVFoundation
import VanishCore

// usage: vanishcam [--effect dissolve|substitution|teleport] [--camera N] [--hold SECONDS] [--background IMAGE] [--recapture] [--gesture-debug] [--list]
let args = CommandLine.arguments
var dumpPath: String?
func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("VanishCam")
try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
let plateURL = support.appendingPathComponent("plate.png")

if let bg = opt("--background") {   // custom background image -> becomes the saved plate
    do {
        let pb = try PixelBufferIO.loadImage(at: URL(fileURLWithPath: (bg as NSString).expandingTildeInPath), width: 1920, height: 1080)
        try PixelBufferIO.writePNG(pb, to: plateURL); print("custom background saved")
    } catch { print("could not load background: \(error)"); exit(1) }
}
if args.contains("--recapture") { try? FileManager.default.removeItem(at: plateURL) }

let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified)
let devices = ds.devices
if args.contains("--list") { for (i, d) in devices.enumerated() { print("\(i): \(d.localizedName)") }; exit(0) }

let sink = ObsSink()
guard sink.connect() else { print("OBS Virtual Camera not found: start it once in OBS, then quit OBS."); exit(1) }

var settings = VanishPipeline.Settings(plateURL: plateURL)
if let h = opt("--hold").flatMap(Double.init) { settings.holdSeconds = h }
settings.debug = args.contains("--gesture-debug")
if let e = opt("--effect") {
    guard let k = EffectKind(rawValue: e) else {
        print("unknown effect '\(e)': use dissolve | substitution | teleport"); exit(1) }
    settings.effect = k; settings.enabled = [k]
}
if let d = opt("--dump") { dumpPath = d; print("[dump] saving to \(d)-bgra.png / -uyvy.png every ~3 s") }

let pipeline: VanishPipeline
let converter: UYVYConverter
do {
    let renderer = try EffectRenderer()
    pipeline = try VanishPipeline(settings: settings, renderer: renderer,
                                  detector: VisionGestureDetector(), segmenter: VisionPersonSegmenter())
    converter = try UYVYConverter(device: renderer.device, queue: renderer.commandQueue)
} catch { print("setup failed: \(error)"); exit(1) }

final class Cam: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession(); var n = 0; var t = Date()
    func start(_ dev: AVCaptureDevice) throws {
        session.sessionPreset = .hd1280x720
        session.addInput(try AVCaptureDeviceInput(device: dev))
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cam", qos: .userInteractive))
        session.addOutput(out); session.startRunning()
    }
    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sb), let out = pipeline.process(pb) else { return }
        if let uyvy = converter.convert(out) {
            sink.send(uyvy)
            if dumpPath != nil, n % 90 == 0 {
                try? PixelBufferIO.writePNG(out, to: URL(fileURLWithPath: dumpPath! + "-bgra.png"))
                CVPixelBufferLockBaseAddress(uyvy, .readOnly)
                let p = CVPixelBufferGetBaseAddress(uyvy)!.assumingMemoryBound(to: UInt8.self)
                var sum = 0; let cnt = CVPixelBufferGetDataSize(uyvy) / 2
                for i in stride(from: 1, to: cnt * 2, by: 997) { sum += Int(p[i]) }
                CVPixelBufferUnlockBaseAddress(uyvy, .readOnly)
                print("[dump] avg Y = \(sum / (cnt / 997 + 1))")
                try? PixelBufferIO.writePNG(uyvy, to: URL(fileURLWithPath: dumpPath! + "-uyvy.png"))
            }
        }
        n += 1
        if Date().timeIntervalSince(t) >= 5 { print(String(format: "[vanishcam] %.1f fps", Double(n) / Date().timeIntervalSince(t))); n = 0; t = Date() }
    }
}
let cam = Cam()
AVCaptureDevice.requestAccess(for: .video) { ok in
    guard ok else { print("camera permission denied"); exit(1) }
    let idx = opt("--camera").flatMap(Int.init)
    guard let dev = idx.flatMap({ devices.indices.contains($0) ? devices[$0] : nil }) ?? devices.first(where: { $0.localizedName != "OBS Virtual Camera" }) else { print("no camera"); exit(1) }
    print("[vanishcam] using \(dev.localizedName)  |  keys: v = vanish/reappear, c = recapture background, q = quit")
    do { try cam.start(dev) } catch { print("camera error: \(error)"); exit(1) }
}
DispatchQueue.global().async {
    while let line = readLine() {
        switch line.trimmingCharacters(in: .whitespaces).lowercased() {
        case "v": pipeline.toggle()
        case "c": pipeline.recapture()
        case "q": exit(0)
        default: break
        }
    }
}
RunLoop.main.run()
