import SwiftUI
import VanishCore

/// Guided capture: per step a 1 s countdown, then 3 s of `detector.lastFeatures` samples (polled at 10 Hz).
@MainActor
private final class CalibrationRunner: ObservableObject {
    static let steps: [(text: String, label: String)] = [
        ("V sign", "vSign"), ("V sign, other hand", "vSign"), ("V sign tilted, fingers a bit closer", "vSign"),
        ("Hand seal", "handSeal"), ("Hand seal rotated / lower", "handSeal"),
        ("Open palm", "none"), ("Two fingers together, not the seal", "none"), ("Prayer hands", "none"),
        ("Fist", "none"), ("Hand near your face", "none"), ("No hands in view", "none"),
    ]
    @Published var step = 0
    @Published var phase = "Get ready…"
    @Published var done = false
    private var task: Task<Void, Never>?

    func run(engine: CameraEngine) {
        task = Task {
            var samples = GestureSamples()
            for (i, s) in Self.steps.enumerated() {
                step = i; phase = "Get ready…"
                try? await Task.sleep(for: .seconds(1))
                phase = "Hold it…"
                for _ in 0..<30 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if Task.isCancelled { return }
                    // ponytail: no hand seen = skipped; the "no hands" step is the only one that keeps count 0
                    if let f = engine.detector.lastFeatures, (f.last ?? 0) > 0 || s.text == "No hands in view" {
                        samples.add(label: s.label, features: f)
                    }
                }
            }
            let n = { (l: String) in samples.samples.filter { $0.label == l }.count }
            guard n("vSign") >= 10, n("handSeal") >= 10 else { phase = "Hands not seen enough. Close and try again."; return }
            engine.saveSamples(samples)
            done = true
        }
    }
    func cancel() { task?.cancel() }
}

struct CalibrationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = CalibrationRunner()

    var body: some View {
        VStack(spacing: 14) {
            if runner.done {
                Text("Calibration saved").font(.title2)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Text("Step \(runner.step + 1)/\(CalibrationRunner.steps.count)").foregroundStyle(.secondary)
                Text(CalibrationRunner.steps[runner.step].text).font(.title2)
                Text(runner.phase)
                Button("Cancel") { runner.cancel(); dismiss() }
            }
        }
        .padding(24)
        .frame(width: 340)
        .onAppear { model.engine.beginCalibration(); runner.run(engine: model.engine) }
        .onDisappear { runner.cancel(); model.engine.endCalibration(settings: model.settings) }
    }
}
