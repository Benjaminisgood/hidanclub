import XCTest
@testable import HidanCore

final class SequenceBuilderTests: XCTestCase {
    func testSequenceUsesOnlySelectedMovesAndAlwaysContainsFourEightCounts() throws {
        let selection = ["hiphop-bounce", "hiphop-step-touch"]
        let sequence = try SequenceBuilder.make(moveIDs: selection, bpm: 90, seed: 6)
        XCTAssertEqual(sequence.slots.count, 4)
        XCTAssertTrue(sequence.slots.allSatisfy { $0.beats == 8 })
        XCTAssertTrue(sequence.slots.allSatisfy { selection.contains($0.moveID) })
        XCTAssertEqual(sequence.slots.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(sequence.totalBeats, 32)
        XCTAssertEqual(sequence.durationSeconds, 32 * 60 / 90.0, accuracy: 0.00001)
        XCTAssertEqual(Set(sequence.slots.map(\.id)).count, 4)
        XCTAssertEqual(sequence.slots.last?.beatRange, 25...32)
    }

    func testModerateImpactMoveIsExcludedAndExplained() throws {
        let sequence = try SequenceBuilder.make(moveIDs: ["hiphop-running-man", "hiphop-bounce"], bpm: 80)
        XCTAssertTrue(sequence.slots.allSatisfy { $0.moveID == "hiphop-bounce" })
        XCTAssertTrue(sequence.warnings.contains { $0.contains("奔跑步") })
        XCTAssertThrowsError(try SequenceBuilder.make(moveIDs: ["hiphop-running-man"], bpm: 80)) { error in
            XCTAssertEqual(error as? SequenceError, .noEligibleMoves)
        }
    }

    func testMissingPrerequisitesAndTempoAreVisible() throws {
        let sequence = try SequenceBuilder.make(moveIDs: ["popping-arm-wave"], bpm: 150)
        XCTAssertTrue(sequence.warnings.contains { $0.contains("胸肩分离") })
        XCTAssertTrue(sequence.warnings.contains { $0.contains("BPM") })
        XCTAssertTrue(sequence.warnings.contains { $0.contains("熟练度") })
    }

    func testMixedStylesAreVisibleAndSelectedPrerequisitesAreAcknowledged() throws {
        let sequence = try SequenceBuilder.make(moveIDs: ["hiphop-bounce", "house-jack"], bpm: 85)
        XCTAssertTrue(sequence.warnings.contains { $0.contains("多个风格") })
        let prepared = try SequenceBuilder.make(moveIDs: ["popping-isolation", "popping-arm-wave"], bpm: 65)
        XCTAssertFalse(prepared.warnings.contains { $0.contains("未包含") })
        XCTAssertTrue(prepared.warnings.contains { $0.contains("熟练度") })
    }

    func testInvalidInputCannotCreateBrokenSequence() {
        for bpm in [Double.nan, .infinity, -.infinity, 0, 39.9, 201] {
            XCTAssertThrowsError(try SequenceBuilder.make(moveIDs: ["hiphop-bounce"], bpm: bpm)) { error in
                XCTAssertEqual(error as? SequenceError, .invalidBPM)
            }
        }
        XCTAssertThrowsError(try SequenceBuilder.make(moveIDs: [], bpm: 90))
        XCTAssertThrowsError(try SequenceBuilder.make(moveIDs: ["missing"], bpm: 90)) { error in
            XCTAssertEqual(error as? SequenceError, .unknownMove("missing"))
        }
    }

    func testStandingConstraintCannotBeBypassedByCustomCatalog() {
        let move = DanceMove(id: "floor", name: "Ground movement", englishName: "Ground movement", style: .hipHop,
                             summary: "Test", cues: ["Test"], commonMistakes: [], bpmMin: 60, bpmMax: 100,
                             suitableForStandingPractice: false)
        XCTAssertThrowsError(try SequenceBuilder.make(moveIDs: [move.id], catalog: [move], bpm: 80)) { error in
            XCTAssertEqual(error as? SequenceError, .noEligibleMoves)
        }
    }

    func testSequenceIsReproducibleAndCodable() throws {
        let ids = ["hiphop-bounce", "hiphop-rock", "hiphop-step-touch", "locking-point"]
        let sequence = try SequenceBuilder.make(moveIDs: ids, bpm: 90, seed: Int.min)
        XCTAssertEqual(sequence, try SequenceBuilder.make(moveIDs: ids, bpm: 90, seed: Int.min))
        let data = try JSONEncoder().encode(sequence)
        XCTAssertEqual(try JSONDecoder().decode(DanceSequence.self, from: data), sequence)
    }
}
