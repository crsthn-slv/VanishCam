import SwiftUI
import Vision
import VanishCore

/// Manual guided capture: per step Record -> 3-2-1 -> 3 s of `detector.lastFeatures` samples (10 Hz) -> Redo / Next.
@MainActor
private final class CalibrationRunner: ObservableObject {
    static let steps: [(text: String, label: String, hint: String)] = [
        ("V sign", "vSign", "Index and middle finger up, apart"),
        ("V sign, other hand", "vSign", "Same sign with your other hand"),
        ("V sign tilted, fingers a bit closer", "vSign", "Tilt the hand, fingers closer together"),
        ("Hand seal", "handSeal", "Both hands clasped, index fingers up together"),
        ("Hand seal rotated / lower", "handSeal", "Same seal, rotated or held lower"),
        ("Two fingers on forehead", "teleport", "Index and middle together, fingertips on your forehead"),
        ("Forehead, slightly different angle", "teleport", "Same sign, turn the hand or your head a little"),
        ("Open palm", "none", "Fingers spread, palm to the camera"),
        ("Two fingers pointing sideways", "none", "One hand, index and middle together, pointing to the side"),
        ("Prayer hands", "none", "Palms together, fingers up"),
        ("Fist", "none", "Closed fist"),
        ("Hand near your face", "none", "Any relaxed hand next to your face"),
        ("Scratching / touching your face", "none", "Scratch your cheek, rub your eyes, touch your chin"),
        ("No hands in view", "none", "Lower both hands out of the frame"),
    ]
    enum Phase: Equatable { case idle, countdown(Int), capturing, captured }
    @Published var step = 0
    @Published var phase = Phase.idle
    @Published var progress = 0.0
    @Published var count = 0
    @Published var error: String?
    @Published var done = false
    private var samples = [[[Double]]](repeating: [], count: steps.count)
    private var task: Task<Void, Never>?

    var needsRedo: Bool { phase == .captured && Self.steps[step].label != "none" && count < 10 }
    var isLast: Bool { step == Self.steps.count - 1 }

    func record(engine: CameraEngine) {
        let s = Self.steps[step]
        task = Task {
            for n in [3, 2, 1] {
                phase = .countdown(n)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            phase = .capturing; progress = 0; count = 0; samples[step] = []
            for i in 1...30 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                // ponytail: no hand seen = skipped; the "no hands" step is the only one that keeps count 0
                if let f = engine.detector.lastFeatures, (f.last ?? 0) > 0 || s.text == "No hands in view" {
                    samples[step].append(f); count += 1
                }
                progress = Double(i) / 30
            }
            phase = .captured
        }
    }

    func redo() { samples[step] = []; count = 0; progress = 0; phase = .idle }

    func next(engine: CameraEngine) {
        if !isLast { step += 1; phase = .idle; progress = 0; count = 0; return }
        var all = GestureSamples()
        for (i, s) in Self.steps.enumerated() { for f in samples[i] { all.add(label: s.label, features: f) } }
        let n = { (l: String) in all.samples.filter { $0.label == l }.count }
        guard n("vSign") >= 10, n("handSeal") >= 10, n("teleport") >= 10 else {
            error = "Hands not seen enough in the V sign / seal / forehead steps. Redo them or cancel."; return
        }
        engine.saveSamples(all)
        done = true
    }

    func cancel() { task?.cancel() }
}

/// Mirrored (selfie) camera frame with hand bones on top.
private struct PreviewView: View {
    let engine: CameraEngine
    private static let chains: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip],
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15)) { _ in
            let image = engine.previewFrame, hands = engine.detector.lastHands
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                    ctx.translateBy(x: size.width, y: 0); ctx.scaleBy(x: -1, y: 1)   // mirror image + bones
                    if let image { ctx.draw(Image(decorative: image, scale: 1), in: CGRect(origin: .zero, size: size)) }
                    let pt = { (p: CGPoint) in CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height) }
                    for h in hands {
                        for chain in Self.chains {
                            var path = Path()
                            let pts = chain.compactMap { h[$0] }.map(pt)
                            guard let first = pts.first else { continue }
                            path.move(to: first); pts.dropFirst().forEach { path.addLine(to: $0) }
                            ctx.stroke(path, with: .color(.green), lineWidth: 3)
                        }
                        for p in h.values.map(pt) {
                            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.white))
                        }
                    }
                }
                if hands.isEmpty {
                    Text("No hand detected").padding(6).background(.black.opacity(0.6)).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6)).padding(8)
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = CalibrationRunner()

    var body: some View {
        VStack(spacing: 12) {
            if runner.done {
                Text("Calibration saved").font(.title2)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                let s = CalibrationRunner.steps[runner.step]
                Text("Step \(runner.step + 1)/\(CalibrationRunner.steps.count)").foregroundStyle(.secondary)
                Text(s.text).font(.title2)
                Text(s.hint).foregroundStyle(.secondary)
                PreviewView(engine: model.engine)
                controls
                if let e = runner.error { Text(e).foregroundStyle(.red) }
                Button("Cancel") { runner.cancel(); dismiss() }
            }
        }
        .padding(24)
        .frame(width: 680, height: 620)
        .onAppear { model.engine.beginCalibration() }
        .onDisappear { runner.cancel(); model.engine.endCalibration(settings: model.settings) }
    }

    @ViewBuilder private var controls: some View {
        switch runner.phase {
        case .idle:
            Button("Record") { runner.record(engine: model.engine) }.keyboardShortcut(.defaultAction)
        case .countdown(let n):
            Text("\(n)").font(.system(size: 40, weight: .bold))
        case .capturing:
            ProgressView(value: runner.progress).frame(width: 300)
            Text("\(runner.count) samples")
        case .captured:
            Text("\(runner.count) samples")
            if runner.needsRedo { Text("Hand not seen enough. Redo.").foregroundStyle(.orange) }
            HStack {
                Button("Redo") { runner.redo() }
                Button(runner.isLast ? "Save" : "Next") { runner.next(engine: model.engine) }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
