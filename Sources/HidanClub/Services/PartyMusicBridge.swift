import Combine
import Foundation

/// The music bar is the shared beat: a host's play, pause, tempo and source
/// changes are mirrored to the friend; a following guest hears the built-in
/// beat at the host's effective tempo (imported tracks never leave the host).
extension MusicService: PartyBeatPlayer {
    var partyBeatSnapshot: PartyBeatSnapshot {
        let effective: Double?
        switch tempoMode {
        case .beat: effective = bpm
        case .music:
            let value = (trackBPM ?? 0) * Double(rate)
            effective = value.isFinite && value > 0 ? value : nil
        }
        return PartyBeatSnapshot(isPlaying: isPlaying, isPaused: isPaused, isBeat: tempoMode == .beat,
                                 bpm: effective, sourceName: trackName, isTrack: tempoMode == .music)
    }

    var beatChanges: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }

    func prepareSharedBeat(name: String, bpm: Double) { useNamedBeat(name: name, bpm: bpm, resume: false) }
    func playSharedBeat() { play() }
    func pauseSharedBeat() { pause() }
    func stopSharedBeat() { stop() }
}
