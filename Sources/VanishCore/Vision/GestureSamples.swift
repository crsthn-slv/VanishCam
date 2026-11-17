import Foundation

/// Per-user labeled gesture samples (`GestureGeometry.features` vectors) and a kNN classifier over them.
/// Labels: "vSign", "handSeal", "none" (confusers). Call `prepared()` once after adding samples so
/// `classify` doesn't recompute normalization and threshold every frame.
public struct GestureSamples: Codable, Sendable {
    public struct Sample: Codable, Sendable {
        public var label: String
        public var features: [Double]
    }
    public private(set) var samples: [Sample] = []
    private var model: Model?

    private enum CodingKeys: String, CodingKey { case samples }
    static let k = 5

    public init() {}
    public var isEmpty: Bool { samples.isEmpty }

    public mutating func add(label: String, features: [Double]) {
        samples.append(Sample(label: label, features: features))
        model = nil
    }

    /// Copy with normalization and rejection threshold cached.
    public func prepared() -> GestureSamples {
        var s = self
        s.model = Model(samples)
        return s
    }

    /// kNN (k=5, majority, tie -> nearest) on z-scored features. `.none` if no usable samples or the
    /// nearest sample is farther than the rejection threshold. `distance` = nearest distance (z units).
    public func classify(_ f: [Double]) -> (gesture: Gesture, distance: Double) {
        guard let m = model ?? Model(samples), f.count == m.mean.count else { return (.none, .infinity) }
        let q = m.normalize(f)
        // ponytail: linear scan, fine for ~500 samples; KD-tree if calibration sets grow much larger.
        let near = m.z.indices.map { (i: $0, d: euclid(q, m.z[$0])) }.sorted { $0.d < $1.d }.prefix(Self.k)
        guard let first = near.first else { return (.none, .infinity) }
        if first.d > m.threshold { return (.none, first.d) }
        var votes: [String: Int] = [:]
        for n in near { votes[m.labels[n.i], default: 0] += 1 }
        let top = votes.values.max() ?? 0
        let label = near.first { votes[m.labels[$0.i]] == top }.map { m.labels[$0.i] } ?? "none"
        return (Self.gesture(label), first.d)
    }

    static func gesture(_ label: String) -> Gesture {
        switch label {
        case "vSign": return .vSign
        case "handSeal": return .handSeal
        default: return .none
        }
    }

    struct Model: Sendable {
        var mean: [Double], std: [Double], z: [[Double]], labels: [String], threshold: Double

        /// Uses only samples matching the most common feature length (stale/mismatched ones are ignored).
        init?(_ all: [Sample]) {
            let lengths = Dictionary(grouping: all, by: { $0.features.count })
            guard let n = lengths.max(by: { $0.value.count < $1.value.count })?.key, n > 0 else { return nil }
            let s = all.filter { $0.features.count == n }
            let c = Double(s.count)
            let mu = (0..<n).map { j in s.reduce(0) { $0 + $1.features[j] } / c }
            let sd = (0..<n).map { j in max(sqrt(s.reduce(0) { $0 + pow($1.features[j] - mu[j], 2) } / c), 1e-3) }
            let lb = s.map(\.label)
            let zs = s.map { x in x.features.indices.map { (x.features[$0] - mu[$0]) / sd[$0] } }
            // Rejection: 1.5 x 95th percentile of each sample's leave-one-out nearest same-class distance.
            var nn: [Double] = []
            for i in zs.indices {
                let d = zs.indices.filter { $0 != i && lb[$0] == lb[i] }.map { euclid(zs[i], zs[$0]) }.min()
                if let d { nn.append(d) }
            }
            nn.sort()
            mean = mu; std = sd; labels = lb; z = zs
            threshold = nn.isEmpty ? .infinity : 1.5 * nn[min(nn.count - 1, Int(Double(nn.count) * 0.95))]
        }
        func normalize(_ f: [Double]) -> [Double] { f.indices.map { (f[$0] - mean[$0]) / std[$0] } }
    }
}

private func euclid(_ a: [Double], _ b: [Double]) -> Double {
    sqrt(zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
}
