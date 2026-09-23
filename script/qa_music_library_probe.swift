import AVFoundation
import Foundation
import HidanCore

@main struct MusicLibraryProbe {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }
    @MainActor static func wait(_ description: String, seconds: Double = 30, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            if Date() > deadline { throw Failure(description: "Timed out: \(description)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = root.appendingPathComponent("clicks-120.wav")
        try writeClicks(to: source, bpm: 120, seconds: 16, hats: true)
        let original = try Data(contentsOf: source)
        let folder = root.appendingPathComponent("Music", isDirectory: true)
        let library = MusicLibraryStore(directory: folder)
        try await wait("library loads") { !library.isLoading }
        try require(library.tracks.isEmpty && library.consumeSavedSelection()?.track == nil, "Isolated library did not start empty")
        try require(library.presets.map(\.name) == ["慢速八拍", "练习八拍", "俱乐部", "快节奏"], "Starter beats were not installed")
        let created = try library.addBeat(name: " 夜场 ", bpm: 132)
        try require(created.name == "夜场" && library.selectedBeatID == created.id && created.bpm == 132, "Saving a beat did not keep the name and tempo")
        try library.renameBeat(created.id, to: "夜场快")
        library.rememberBeatTempo(140)
        try require(library.selectedBeat?.name == "夜场快" && library.selectedBeat?.bpm == 140, "Renamed beat did not keep the new tempo")

        let imported = await library.importTracks(urls: [source])
        try require(imported.count == 1 && library.errorMessage == nil, "Import did not store the track: \(library.errorMessage ?? "")")
        let track = imported[0]
        try require(track.channelCount == 2 && abs(track.duration - 16) < 0.05 && track.needsAnalysis, "Imported metadata did not keep duration, channels and a pending analysis")
        let copy = try library.url(for: track)
        try require(try Data(contentsOf: copy) == original, "Stored audio is not a byte copy of the source")
        try require(try Data(contentsOf: source) == original, "Import rewrote the source file")
        try await wait("tempo analysis") { library.track(track.id)?.tempo != nil || library.track(track.id)?.analysisFailure != nil }
        try await wait("analysis idle") { !library.analyzing.contains(track.id) }
        guard let tempo = library.track(track.id)?.tempo else {
            throw Failure(description: "120 BPM clicks were not estimated: \(library.track(track.id)?.analysisFailure ?? "")")
        }
        try require(abs(tempo.bpm - 120) < 2, "120 BPM hat grid estimated as \(tempo.bpm)")
        try require(tempo.confidence >= TempoEstimator.minimumConfidence && tempo.analyzedSeconds > 8 && tempo.method == MusicBeatAnalyzer.method, "Estimate did not record how it was made")

        let slower = root.appendingPathComponent("clicks-86.wav")
        try writeClicks(to: slower, bpm: 86, seconds: 18, hats: true, sampleRate: 48000, channels: 1)
        async let again: [LibraryTrack] = library.importTracks(urls: [source])
        async let other: [LibraryTrack] = library.importTracks(urls: [slower])
        let batch = await again + other
        try require(batch.count == 2 && library.tracks.count == 3, "Concurrent imports dropped a track")
        let monoID = library.tracks.first { $0.originalFilename == slower.lastPathComponent }?.id
        try require(library.track(monoID)?.sampleRate == 48000 && library.track(monoID)?.channelCount == 1, "Sample rate or channel count was not taken from the file")
        try await wait("second analysis") { library.analyzing.isEmpty && library.tracks.allSatisfy { !$0.needsAnalysis } }
        if let bpm = library.track(monoID)?.tempo?.bpm {
            try require(abs(bpm - 86) < 2, "86 BPM file estimated as \(bpm)")
        } else {
            throw Failure(description: "86 BPM file was not estimated: \(library.track(monoID)?.analysisFailure ?? "missing")")
        }

        library.select(track.id)
        library.setMultiplier(.double)
        let reopened = MusicLibraryStore(directory: folder)
        try await wait("reopen") { !reopened.isLoading }
        try require(reopened.tracks.count == 3, "Tracks did not survive relaunch")
        let saved = reopened.consumeSavedSelection()
        try require(saved?.track?.id == track.id && saved?.multiplier == .double, "Selected track or beat multiple was not restored")
        try require(abs((reopened.track(track.id)?.effectiveBPM ?? 0) - tempo.bpm) < 0.001, "Estimated BPM changed across relaunch")

        try reopened.setManualBPM(track.id, bpm: 96)
        try require(reopened.track(track.id)?.effectiveBPM == 96 && reopened.track(track.id)?.tempo?.bpm == tempo.bpm, "Manual BPM did not override the estimate without replacing it")
        do { try reopened.setManualBPM(track.id, bpm: 12); throw Failure(description: "BPM below 30 was accepted") }
        catch MusicLibraryError.invalidBPM { }
        try require(reopened.track(track.id)?.manualBPM == 96, "Rejected BPM overwrote the correction")
        let corrected = MusicLibraryStore(directory: folder)
        try await wait("correction reload") { !corrected.isLoading }
        try require(corrected.track(track.id)?.effectiveBPM == 96, "Manual BPM did not persist")
        try corrected.setManualBPM(track.id, bpm: nil)
        try require(corrected.track(track.id)?.manualBPM == nil && abs((corrected.track(track.id)?.effectiveBPM ?? 0) - tempo.bpm) < 0.001, "Clearing the correction did not return the estimate")

        let brief = root.appendingPathComponent("too-short.wav")
        try writeClicks(to: brief, bpm: 100, seconds: 2, hats: true)
        let short = await library.importTracks(urls: [brief])
        try require(short.count == 1, "Short audio was refused at import")
        try await wait("short analysis settles") { library.track(short[0].id)?.analysisFailure != nil }
        try require(library.track(short[0].id)?.tempo == nil && library.track(short[0].id)?.needsAnalysis == false, "A failed estimate would be retried on every launch")

        let junk = root.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: junk)
        let before = library.tracks.count
        let rejected = await library.importTracks(urls: [junk])
        try require(rejected.isEmpty && library.tracks.count == before && library.errorMessage != nil, "Unreadable audio entered the library")

        let metadata = folder.appendingPathComponent(track.id.uuidString.lowercased() + ".json")
        let damaged = Data("keep this damaged record".utf8)
        try damaged.write(to: metadata)
        do { try library.setManualBPM(track.id, bpm: 100); throw Failure(description: "Damaged metadata was overwritten") }
        catch MusicLibraryError.corruptedExistingFile { }
        try require(try Data(contentsOf: metadata) == damaged, "Damaged metadata bytes changed")

        let outside = root.appendingPathComponent("outside.wav")
        try original.write(to: outside)
        try FileManager.default.removeItem(at: copy)
        try FileManager.default.createSymbolicLink(at: copy, withDestinationURL: outside)
        do { _ = try library.url(for: track); throw Failure(description: "Symlinked original was accepted") }
        catch MusicLibraryError.missingAudio { }

        let beatFile = folder.appendingPathComponent("beats.json")
        let beatBytes = try Data(contentsOf: beatFile)
        let reopenedBeats = MusicLibraryStore(directory: folder)
        try await wait("beats reopen") { !reopenedBeats.isLoading }
        try require(reopenedBeats.presets.contains { $0.name == "夜场快" && $0.bpm == 140 }, "Saved beat did not survive relaunch")
        reopenedBeats.deleteBeat(created.id)
        try require(!reopenedBeats.presets.contains { $0.id == created.id }, "Deleted beat stayed in memory")
        let damagedBeats = Data("keep damaged beats".utf8)
        try damagedBeats.write(to: beatFile)
        do { _ = try reopenedBeats.addBeat(name: "另一套", bpm: 90); throw Failure(description: "Damaged beat file was overwritten") }
        catch MusicLibraryError.corruptedExistingFile { }
        try require(try Data(contentsOf: beatFile) == damagedBeats, "Damaged beat file bytes changed")
        _ = beatBytes

        print("PASS: byte-identical music copies, local tempo, manual BPM, relaunch selection and multiples, saved original beats, short-file failure retained, junk rejected, damaged metadata and symlink originals refused.")
    }

    static func writeClicks(to url: URL, bpm: Double, seconds: Double, hats: Bool, sampleRate: Double = 44100, channels: AVAudioChannelCount = 2) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let count = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let beat = sampleRate * 60 / bpm
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(count) { samples[frame] = 0 }
            func burst(from start: Double, seconds length: Double, frequency: Double, amplitude: Float, decay: Double) {
                let begin = Int(start)
                let frames = min(Int(sampleRate * length), Int(count) - begin)
                guard frames > 0 else { return }
                for index in 0..<frames {
                    let time = Double(index) / sampleRate
                    samples[begin + index] += Float(sin(2 * .pi * frequency * time) * exp(-time * decay)) * amplitude
                }
            }
            var cursor = 0.0
            while cursor < Double(count) {
                burst(from: cursor, seconds: 0.04, frequency: 70, amplitude: 0.9, decay: 35)
                cursor += beat
            }
            if hats {
                cursor = beat / 2
                while cursor < Double(count) {
                    burst(from: cursor, seconds: 0.01, frequency: 4500, amplitude: 0.35, decay: 180)
                    cursor += beat
                }
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
