import XCTest
@testable import HidanCore

final class TrainingPlanTests: XCTestCase {
    func testEverySupportedDurationStyleAndLevelHasExactBudgetAndRecovery() throws {
        for style in DanceStyle.allCases {
            for level in 1...2 {
                for minutes in 10...45 {
                    let plan = try PlanBuilder.make(durationMinutes: minutes, style: style, level: level, seed: 31)
                    XCTAssertEqual(plan.totalSeconds, minutes * 60)
                    XCTAssertEqual(plan.blocks.first?.kind, .warmup)
                    XCTAssertEqual(plan.blocks.last?.kind, .cooldown)
                    XCTAssertTrue(plan.blocks.contains { $0.kind == .rest })
                    XCTAssertTrue(plan.blocks.allSatisfy { $0.durationSeconds > 0 })
                    XCTAssertEqual(Set(plan.blocks.map(\.id)).count, plan.blocks.count)
                    var practiced: Set<String> = []
                    for block in plan.blocks where block.kind == .drill {
                        let move = try XCTUnwrap(DanceCatalog.move(id: try XCTUnwrap(block.moveID)))
                        XCTAssertEqual(move.style, style)
                        XCTAssertLessThanOrEqual(move.level, level)
                        XCTAssertTrue(Set(move.prerequisites).isSubset(of: practiced),
                                      "An unfamiliar prerequisite should be introduced before \(move.id)")
                        practiced.insert(move.id)
                    }
                }
            }
        }
    }

    func testInvalidRequestsFailInsteadOfSilentlyChangingUserDuration() {
        for minutes in [Int.min, -1, 0, 9, 46, Int.max] {
            XCTAssertThrowsError(try PlanBuilder.make(durationMinutes: minutes, style: .hipHop)) { error in
                XCTAssertEqual(error as? TrainingPlanError, .durationOutOfRange)
            }
        }
        XCTAssertThrowsError(try PlanBuilder.make(durationMinutes: 15, style: .hipHop, level: 0))
        XCTAssertThrowsError(try PlanBuilder.make(durationMinutes: 15, style: .hipHop, level: 3))
    }

    func testSeedIsReproducibleIncludingExtremeIntegerValues() throws {
        for seed in [0, -1, 42, Int.min, Int.max] {
            let first = try PlanBuilder.make(durationMinutes: 20, style: .hipHop, level: 2, seed: seed)
            let second = try PlanBuilder.make(durationMinutes: 20, style: .hipHop, level: 2, seed: seed)
            XCTAssertEqual(first, second)
        }
    }

    func testCatalogReferencesResolveAndLevelsHaveFoundations() throws {
        let moves = DanceCatalog.moves
        XCTAssertGreaterThanOrEqual(moves.count, 12)
        XCTAssertEqual(Set(moves.map(\.id)).count, moves.count)
        for move in moves {
            XCTAssertFalse(move.cues.isEmpty)
            XCTAssertFalse(move.commonMistakes.isEmpty)
            XCTAssertLessThanOrEqual(move.bpmMin, move.bpmMax)
            XCTAssertTrue(move.suitableForStandingPractice)
            for prerequisiteID in move.prerequisites {
                let prerequisite = try XCTUnwrap(DanceCatalog.move(id: prerequisiteID))
                XCTAssertLessThanOrEqual(prerequisite.level, move.level)
                XCTAssertNotEqual(prerequisiteID, move.id)
            }
        }
        for style in DanceStyle.allCases {
            XCTAssertFalse(DanceCatalog.moves(for: style).isEmpty)
        }
    }

    func testPlansAndSessionsRoundTripForPersistence() throws {
        let plan = try PlanBuilder.make(durationMinutes: 15, style: .house)
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(TrainingPlan.self, from: data), plan)
        let session = FinishedSession(date: Date(timeIntervalSince1970: 100), planTitle: plan.title,
                                      activeSeconds: 31.25, completedBlocks: 1,
                                      totalBlocks: plan.blocks.count, perceivedEffort: 4)
        let sessionData = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(FinishedSession.self, from: sessionData), session)
    }
}
