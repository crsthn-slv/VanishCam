import AVFoundation

/// Plays the original effect sounds (see `Assets`). Normal mode is silent, as in the original.
public final class SoundKit {
    public var enabled = true
    public var volume: Float = 0.7
    private var players: [String: AVAudioPlayer] = [:]

    public init() {}

    public func play(asset name: String) {
        guard enabled else { return }
        if players[name] == nil, let url = Assets.url(name) { players[name] = try? AVAudioPlayer(contentsOf: url) }
        guard let p = players[name] else { return }
        p.volume = volume; p.currentTime = 0; p.play()
    }
}
