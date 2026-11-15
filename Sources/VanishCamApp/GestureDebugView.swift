import SwiftUI
import VanishCore

/// Live view of what the gesture detector sees: frame + landmarks + forehead box, and every rule's
/// measured value vs its threshold. Local UI only; polls the pipeline at 10 Hz.
struct GestureDebugView: View {
    @ObservedObject var model: AppModel
    @State private var saved: String?
    @State private var expected = VanishCore.Gesture.vSign

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let f = model.engine.debugFrame, hold = model.engine.holdStatus
            HStack(alignment: .top, spacing: 12) {
                Canvas { ctx, size in draw(f, ctx, size) }
                    .aspectRatio(f?.image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 16.0 / 9, contentMode: .fit)
                    .background(.black)
                    .frame(minWidth: 480)
                ScrollView { readout(f, hold) }.frame(width: 340)
            }
            .padding(12)
        }
        .onAppear { model.debug = true }
        .onDisappear { model.debug = false }
        .frame(minWidth: 880, minHeight: 520)
    }

    // MARK: drawing (Vision coords: normalized, y up)

    private func draw(_ f: GestureDebugFrame?, _ ctx: GraphicsContext, _ size: CGSize) {
        guard let f else { return }
        let pt = { (p: CGPoint) in CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height) }
        let rect = { (r: CGRect) in CGRect(x: r.minX * size.width, y: (1 - r.maxY) * size.height, width: r.width * size.width, height: r.height * size.height) }
        if let img = f.image { ctx.draw(Image(decorative: img, scale: 1), in: CGRect(origin: .zero, size: size)) }
        if let r = f.forehead { ctx.stroke(Path(rect(r)), with: .color(.yellow), style: StrokeStyle(lineWidth: 2, dash: [6, 4])) }
        if let b = f.face?.box { ctx.stroke(Path(rect(b)), with: .color(.cyan), lineWidth: 2) }
        for h in f.hands {
            let col: Color = h.readouts.contains(where: \.pass) ? .green : .red
            for finger in h.fingers {
                var path = Path(); path.addLines(finger.map(pt))
                ctx.stroke(path, with: .color(col), lineWidth: 2)
                for p in finger.map(pt) { ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.white)) }
            }
        }
        for s in f.sample {
            let p = pt(s.tip)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.orange))
        }
    }

    // MARK: readout

    @ViewBuilder private func readout(_ f: GestureDebugFrame?, _ hold: (gesture: VanishCore.Gesture, elapsed: Double, required: Double)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pose: \(String(describing: f?.gesture ?? .none))").font(.headline)
            if let h = hold, h.gesture != .none {
                ProgressView(value: min(h.elapsed, max(h.required, 0.01)), total: max(h.required, 0.01))
                Text(String(format: "hold %.1f / %.1f s (updates during a call)", h.elapsed, h.required)).font(.caption)
            } else { Text("hold: none (updates during a call)").font(.caption).foregroundStyle(.secondary) }
            if let f {
                Text(f.hands.isEmpty ? "no hand found" : f.face == nil ? "no face (forehead box off)" : "forehead: \(f.hands.contains { $0.inForehead } ? "fingertips inside" : "fingertips outside")")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(f.dropped, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
                if let s = f.seal { card(s) }
                ForEach(Array(f.hands.enumerated()), id: \.offset) { i, h in
                    Text("Hand \(i + 1)").font(.subheadline.bold()).padding(.top, 4)
                    ForEach(Array(h.readouts.enumerated()), id: \.offset) { _, r in card(r) }
                }
            }
            Divider()
            HStack {
                Picker("Expected", selection: $expected) {
                    Text("V sign").tag(VanishCore.Gesture.vSign); Text("Hand seal").tag(VanishCore.Gesture.handSeal)
                    Text("Forehead").tag(VanishCore.Gesture.foreheadTwoFingers); Text("None").tag(VanishCore.Gesture.none)
                }.labelsHidden().frame(width: 110)
                Button("Record frame") { saved = model.engine.recordFixture(expected: expected)?.path ?? "nothing to record (no hand)" }
            }
            if let saved { Text(saved).font(.caption2).textSelection(.enabled) }
        }
    }

    private func card(_ r: GestureReadout) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(r.pass ? "✓" : "✗") \(r.gesture)").font(.caption.bold()).foregroundStyle(r.pass ? .green : .red)
            ForEach(Array(r.checks.enumerated()), id: \.offset) { _, c in
                Text(String(format: "%@ %@ %.2f %@ %.2f", c.pass ? "✓" : "✗", c.name, c.value, c.atLeast ? "≥" : "≤", c.threshold))
                    .font(.caption.monospacedDigit()).foregroundStyle(c.pass ? Color.secondary : Color.red)
            }
        }
    }
}
