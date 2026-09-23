import XCTest
@testable import HidanCore

final class TempoEstimatorTests: XCTestCase {
    private let fps = 100.0

    func testBareClicksLandOnTheBeatOrItsOctave() throws {
        for bpm in [80.0, 120, 150] {
            let estimate = try TempoEstimator.estimate(onsetEnvelope: clicks(bpm: bpm, seconds: 24), framesPerSecond: fps)
            let ratio = estimate.bpm / bpm
            let octave = abs(ratio - 1) < 0.02 || abs(ratio - 0.5) < 0.02 || abs(ratio - 2) < 0.02
            XCTAssertTrue(octave, "\(bpm) estimated as \(estimate.bpm)")
            XCTAssertEqual(estimate.level, .high)
        }
    }

    func testEighthNoteOnsetsSelectTheQuarterNote() throws {
        for bpm in [100.0, 120, 150] {
            var envelope = clicks(bpm: bpm, seconds: 24)
            var cursor = 60 / (bpm * 2) * fps
            while Int(cursor.rounded()) < envelope.count {
                envelope[Int(cursor.rounded())] = 0.45
                cursor += 60 / bpm * fps
            }
            let estimate = try TempoEstimator.estimate(onsetEnvelope: envelope, framesPerSecond: fps)
            XCTAssertEqual(estimate.bpm, bpm, accuracy: 1)
        }
    }

    func testUnusableEnvelopesAreRejected() {
        XCTAssertThrowsError(try TempoEstimator.estimate(onsetEnvelope: [1, .nan], framesPerSecond: fps)) { error in
            XCTAssertEqual(error as? TempoEstimationError, .invalidInput)
        }
        XCTAssertThrowsError(try TempoEstimator.estimate(onsetEnvelope: clicks(bpm: 120, seconds: 3), framesPerSecond: fps)) { error in
            XCTAssertEqual(error as? TempoEstimationError, .tooShort)
        }
        XCTAssertThrowsError(try TempoEstimator.estimate(onsetEnvelope: Array(repeating: 0, count: Int(fps * 16)), framesPerSecond: fps)) { error in
            XCTAssertEqual(error as? TempoEstimationError, .noPeriodicity)
        }
    }

    func testMusicTempoMathAndDoubleTimeSpeed() throws {
        XCTAssertEqual(MotionTempo.musicTarget(trackBPM: 100, rate: 0.75, multiplier: .double), 150)
        XCTAssertEqual(MotionTempo.speed(motionBPM: 80, targetBPM: 120), 1.5)
        XCTAssertEqual(MotionTempo.speed(motionBPM: 50, targetBPM: 200), 2)
        XCTAssertFalse(MotionTempo.canReach(motionBPM: 50, targetBPM: 200))
        XCTAssertEqual(MotionTempo.clampBeat(.nan), 90)
        let sequence = try JSONDecoder().decode(AISTSequence.self, from: Data("""
        {"id":"gMH_sBM_cAll_d01_mMH0_ch01","genreCode":"gMH","genreName":"Hip-hop","dancerID":"d01","musicID":"mMH0","frameCount":8,"fps":60,"rawPath":"sequences/gMH_sBM_cAll_d01_mMH0_ch01.raw.f64","optimizedPath":"sequences/gMH_sBM_cAll_d01_mMH0_ch01.optimized.f64","byteCount":3264,"ignored":false}
        """.utf8))
        XCTAssertEqual(try AISTPracticeReference(sequence: sequence, name: "x", startFrame: 0, endFrame: 1, optimized: true, speed: 2).speed, 2)
        XCTAssertThrowsError(try AISTPracticeReference(sequence: sequence, name: "x", startFrame: 0, endFrame: 1, optimized: true, speed: 2.01)) { error in
            XCTAssertEqual(error as? AISTPracticeError, .invalidSpeed)
        }
    }

    private func clicks(bpm: Double, seconds: Double) -> [Double] {
        let count = Int(fps * seconds)
        var envelope = [Double](repeating: 0, count: count)
        var cursor = 0.0
        let step = 60 / bpm * fps
        while Int(cursor.rounded()) < count {
            envelope[Int(cursor.rounded())] = 1
            cursor += step
        }
        return envelope
    }
}
