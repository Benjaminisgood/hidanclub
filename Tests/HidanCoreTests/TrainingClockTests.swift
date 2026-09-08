import XCTest
@testable import HidanCore

final class TrainingClockTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000)

    private func date(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

    private func plan() -> TrainingPlan {
        TrainingPlan(id: "clock-test", title: "Clock test", blocks: [
            TrainingBlock(id: "warmup", title: "Warmup", kind: .warmup, durationSeconds: 10, cue: ""),
            TrainingBlock(id: "drill", title: "Drill", kind: .drill, durationSeconds: 20, cue: ""),
            TrainingBlock(id: "rest", title: "Rest", kind: .rest, durationSeconds: 5, cue: ""),
            TrainingBlock(id: "cooldown", title: "Cooldown", kind: .cooldown, durationSeconds: 5, cue: "")
        ])
    }

    func testPausesAreExcludedAndLateTickCapsAtNaturalEnd() throws {
        var clock = TrainingClock(plan: plan())
        XCTAssertTrue(clock.start(at: date(0)))
        XCTAssertFalse(clock.start(at: date(5)))
        XCTAssertFalse(clock.tick(at: date(7)))
        XCTAssertTrue(clock.pause(at: date(8)))
        XCTAssertEqual(clock.activeSeconds, 8)
        XCTAssertEqual(clock.snapshot(at: date(100)).activeSeconds, 8)
        XCTAssertEqual(clock.snapshot(at: date(100)).remainingSeconds, 2)
        XCTAssertFalse(clock.tick(at: date(100)))
        XCTAssertTrue(clock.resume(at: date(108)))
        XCTAssertFalse(clock.tick(at: date(113)))
        XCTAssertEqual(clock.currentBlockIndex, 1)
        XCTAssertEqual(clock.remainingSeconds, 17)
        XCTAssertEqual(clock.activeSeconds, 13)
        XCTAssertTrue(clock.tick(at: date(1_000)))
        XCTAssertEqual(clock.state, .completed)
        XCTAssertEqual(clock.activeSeconds, 40)
        XCTAssertEqual(clock.completedBlocks, 4)
        XCTAssertEqual(clock.finishedAt, date(140))
        XCTAssertFalse(clock.tick(at: date(2_000)))
        XCTAssertFalse(clock.advance(at: date(2_001)))
        XCTAssertFalse(clock.start(at: date(2_001)))
        let firstRecord = try XCTUnwrap(clock.finishedSession())
        let secondRecord = try XCTUnwrap(clock.finishedSession())
        XCTAssertEqual(firstRecord.id, secondRecord.id)
        XCTAssertEqual(firstRecord.activeSeconds, 40)
        XCTAssertEqual(firstRecord.completedBlocks, 4)
    }

    func testSkippingDoesNotInventElapsedTimeOrCompletedBlocks() throws {
        var clock = TrainingClock(plan: plan())
        clock.start(at: date(0))
        XCTAssertFalse(clock.advance(at: date(5)))
        XCTAssertEqual(clock.activeSeconds, 5)
        XCTAssertEqual(clock.currentBlockIndex, 1)
        XCTAssertEqual(clock.completedBlocks, 0)
        clock.tick(at: date(25))
        XCTAssertEqual(clock.currentBlockIndex, 2)
        XCTAssertEqual(clock.completedBlocks, 1)
        clock.pause(at: date(25))
        XCTAssertFalse(clock.advance(at: date(200)))
        XCTAssertEqual(clock.state, .paused)
        XCTAssertEqual(clock.currentBlockIndex, 3)
        XCTAssertEqual(clock.activeSeconds, 25)
        clock.resume(at: date(250))
        XCTAssertTrue(clock.tick(at: date(255)))
        let session = try XCTUnwrap(clock.finishedSession())
        XCTAssertEqual(session.activeSeconds, 30)
        XCTAssertEqual(session.completedBlocks, 2)
        XCTAssertEqual(session.totalBlocks, 4)
    }

    func testSnapshotProjectsWithoutAdvancingStoredState() {
        var clock = TrainingClock(plan: plan())
        clock.start(at: date(0))
        let preview = clock.snapshot(at: date(12.5))
        XCTAssertEqual(preview.blockIndex, 1)
        XCTAssertEqual(preview.remainingSeconds, 17.5)
        XCTAssertEqual(preview.activeSeconds, 12.5)
        XCTAssertEqual(preview.completedBlocks, 1)
        XCTAssertEqual(preview.remainingPlanSeconds, 27.5)
        XCTAssertEqual(clock.activeSeconds, 0)
        XCTAssertEqual(clock.currentBlockIndex, 0)
        clock.tick(at: date(12.5))
        XCTAssertEqual(clock.snapshot(at: date(12.5)), preview)
    }

    func testEarlyStopRecordsOnlyActualTimeAndCannotResume() throws {
        var clock = TrainingClock(plan: plan())
        XCTAssertNil(clock.finishedSession())
        XCTAssertFalse(clock.resume(at: date(0)))
        clock.start(at: date(0))
        XCTAssertNil(clock.finishedSession())
        XCTAssertTrue(clock.stop(at: date(12.25)))
        XCTAssertEqual(clock.state, .stopped)
        XCTAssertFalse(clock.resume(at: date(20)))
        XCTAssertFalse(clock.stop(at: date(20)))
        XCTAssertFalse(clock.tick(at: date(100)))
        let session = try XCTUnwrap(clock.finishedSession(perceivedEffort: 6))
        XCTAssertEqual(session.activeSeconds, 12.25)
        XCTAssertEqual(session.completedBlocks, 1)
        XCTAssertEqual(session.perceivedEffort, 6)
        XCTAssertNil(clock.finishedSession(perceivedEffort: 20)?.perceivedEffort)
    }

    func testBackwardAndRepeatedTimestampsDoNotDuplicateTime() {
        var clock = TrainingClock(plan: plan())
        clock.start(at: date(0))
        clock.tick(at: date(8))
        clock.tick(at: date(4))
        clock.tick(at: date(8))
        XCTAssertEqual(clock.activeSeconds, 8)
        clock.tick(at: date(9))
        XCTAssertEqual(clock.activeSeconds, 9)
        XCTAssertEqual(clock.remainingSeconds, 1)
    }

    func testPauseOnBoundaryPreservesOneNaturalCompletion() {
        var clock = TrainingClock(plan: plan())
        clock.start(at: date(0))
        XCTAssertTrue(clock.pause(at: date(10)))
        XCTAssertEqual(clock.currentBlockIndex, 1)
        XCTAssertEqual(clock.completedBlocks, 1)
        XCTAssertEqual(clock.remainingSeconds, 20)
        clock.stop(at: date(100))
        XCTAssertEqual(clock.activeSeconds, 10)
        XCTAssertEqual(clock.completedBlocks, 1)
    }

    func testCompletingDuringPauseCallDoesNotReplaceCompletionWithPause() {
        var clock = TrainingClock(plan: plan())
        clock.start(at: date(0))
        XCTAssertFalse(clock.pause(at: date(45)))
        XCTAssertEqual(clock.state, .completed)
        XCTAssertEqual(clock.finishedAt, date(40))
        XCTAssertEqual(clock.activeSeconds, 40)
    }
}
