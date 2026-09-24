// Foundation-only regression harness for environments where Command Line Tools
// do not include XCTest. Compile alongside Sources/HidanCore/*.swift, without
// importing the module. The XCTest suite remains the primary package test suite.
import Foundation

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct CoreProbe {
    private static var checks = 0
    private static let epoch = Date(timeIntervalSince1970: 1_000)

    static func main() throws {
        try plansAndCatalog()
        print("PASS: all 288 supported duration/style/level plans; exact time budgets; recovery blocks; prerequisite order; catalog integrity; invalid parameters; deterministic seeds")
        try sequences()
        print("PASS: four eight-count slots; selection constraints; impact/standing exclusions; BPM/style/prerequisite warnings; invalid input; deterministic and Codable sequences")
        try clocks()
        print("PASS: pause exclusion; cross-block catch-up; exact completion date; no duplicate completion; honest skip/stop history; projected snapshots; backward timestamps; boundary transitions")
        try persistence()
        print("PASS: training plan and real session JSON round trips; effort input bounds")
        try tempo()
        print("PASS: bare clicks land on the beat or its octave; hi-hat grids within 1 BPM; short and aperiodic input rejected; beat multiples and speed limits")
        try party()
        print("PASS: party framing under arbitrary chunking with corrupt-stream rejection; typed JSON messages and binary video packets round trip; clock offset from the quietest sample; next eight-count on the shared grid; address and room-code parsing")
        print("CORE PROBE PASSED: \(checks) checks. Foundation-only fallback; XCTest sources were not executed by this harness.")
    }

    private static func expect(_ condition: Bool, _ description: String,
                               file: StaticString = #fileID, line: UInt = #line) throws {
        checks += 1
        guard condition else { throw ProbeFailure(description: "\(file):\(line): \(description)") }
    }

    private static func expectError<E: Error & Equatable>(_ expected: E, _ body: () throws -> Void,
                                                          file: StaticString = #fileID, line: UInt = #line) throws {
        do {
            try body()
        } catch {
            try expect(error as? E == expected, "Expected \(expected), received \(error)", file: file, line: line)
            return
        }
        try expect(false, "Expected \(expected), but operation succeeded", file: file, line: line)
    }

    private static func require<T>(_ value: T?, _ description: String,
                                   file: StaticString = #fileID, line: UInt = #line) throws -> T {
        try expect(value != nil, description, file: file, line: line)
        return value!
    }

    private static func plansAndCatalog() throws {
        for style in DanceStyle.allCases {
            for level in 1...2 {
                for minutes in 10...45 {
                    let plan = try PlanBuilder.make(durationMinutes: minutes, style: style, level: level, seed: 31)
                    let context = "\(style.rawValue), level \(level), \(minutes) minutes"
                    try expect(plan.totalSeconds == minutes * 60, "Exact time budget: \(context)")
                    try expect(plan.blocks.first?.kind == .warmup, "Warmup first: \(context)")
                    try expect(plan.blocks.last?.kind == .cooldown, "Cooldown last: \(context)")
                    try expect(plan.blocks.contains { $0.kind == .rest }, "Scheduled recovery: \(context)")
                    try expect(plan.blocks.allSatisfy { $0.durationSeconds > 0 }, "Positive block times: \(context)")
                    try expect(Set(plan.blocks.map(\.id)).count == plan.blocks.count, "Unique block IDs: \(context)")
                    var practiced: Set<String> = []
                    for block in plan.blocks where block.kind == .drill {
                        let id = try require(block.moveID, "Drill must reference a move")
                        let move = try require(DanceCatalog.move(id: id), "Drill reference resolves")
                        try expect(move.style == style, "Style filter: \(context)")
                        try expect(move.level <= level, "Level filter: \(context)")
                        try expect(Set(move.prerequisites).isSubset(of: practiced), "Prerequisites before \(move.id): \(context)")
                        practiced.insert(move.id)
                    }
                }
            }
        }
        for minutes in [Int.min, -1, 0, 9, 46, Int.max] {
            try expectError(TrainingPlanError.durationOutOfRange) {
                _ = try PlanBuilder.make(durationMinutes: minutes, style: .hipHop)
            }
        }
        for level in [0, 3] {
            try expectError(TrainingPlanError.levelOutOfRange) {
                _ = try PlanBuilder.make(durationMinutes: 15, style: .hipHop, level: level)
            }
        }
        for seed in [0, -1, 42, Int.min, Int.max] {
            let first = try PlanBuilder.make(durationMinutes: 20, style: .hipHop, level: 2, seed: seed)
            let second = try PlanBuilder.make(durationMinutes: 20, style: .hipHop, level: 2, seed: seed)
            try expect(first == second, "Deterministic plan with seed \(seed)")
        }
        let moves = DanceCatalog.moves
        try expect(moves.count >= 12, "Catalog has requested breadth")
        try expect(Set(moves.map(\.id)).count == moves.count, "Unique catalog IDs")
        for move in moves {
            try expect(!move.cues.isEmpty && !move.commonMistakes.isEmpty, "Teaching cues for \(move.id)")
            try expect(move.bpmMin <= move.bpmMax, "Valid BPM range for \(move.id)")
            try expect(move.suitableForStandingPractice, "Standing foundation catalog")
            for prerequisiteID in move.prerequisites {
                let prerequisite = try require(DanceCatalog.move(id: prerequisiteID), "Prerequisite \(prerequisiteID) resolves")
                try expect(prerequisite.level <= move.level, "Prerequisite is not more advanced")
                try expect(prerequisite.id != move.id, "Move does not depend on itself")
            }
        }
        for style in DanceStyle.allCases {
            try expect(!DanceCatalog.moves(for: style).isEmpty, "Beginner foundation for \(style)")
        }
    }

    private static func sequences() throws {
        let selection = ["hiphop-bounce", "hiphop-step-touch"]
        let sequence = try SequenceBuilder.make(moveIDs: selection, bpm: 90, seed: 6)
        try expect(sequence.slots.count == 4, "Exactly four slots")
        try expect(sequence.slots.allSatisfy { $0.beats == 8 }, "Every slot contains eight counts")
        try expect(sequence.slots.allSatisfy { selection.contains($0.moveID) }, "Only selected moves used")
        try expect(sequence.slots.map(\.index) == [0, 1, 2, 3], "Contiguous slot indices")
        try expect(sequence.totalBeats == 32, "Exactly 32 counts")
        try expect(abs(sequence.durationSeconds - 32 * 60 / 90.0) < 0.00001, "Tempo determines sequence duration")
        try expect(Set(sequence.slots.map(\.id)).count == 4, "Unique slot IDs")
        try expect(sequence.slots.last?.beatRange == 25...32, "Last slot's count range")
        let excluded = try SequenceBuilder.make(moveIDs: ["hiphop-running-man", "hiphop-bounce"], bpm: 80)
        try expect(excluded.slots.allSatisfy { $0.moveID == "hiphop-bounce" }, "Moderate impact move excluded")
        try expect(excluded.warnings.contains { $0.contains("奔跑步") }, "Impact exclusion explained")
        try expectError(SequenceError.noEligibleMoves) {
            _ = try SequenceBuilder.make(moveIDs: ["hiphop-running-man"], bpm: 80)
        }
        let unprepared = try SequenceBuilder.make(moveIDs: ["popping-arm-wave"], bpm: 150)
        try expect(unprepared.warnings.contains { $0.contains("胸肩分离") }, "Missing prerequisite named")
        try expect(unprepared.warnings.contains { $0.contains("BPM") }, "Tempo warning visible")
        try expect(unprepared.warnings.contains { $0.contains("熟练度") }, "Mastery is not assumed")
        let mixed = try SequenceBuilder.make(moveIDs: ["hiphop-bounce", "house-jack"], bpm: 85)
        try expect(mixed.warnings.contains { $0.contains("多个风格") }, "Mixed styles explained")
        let prepared = try SequenceBuilder.make(moveIDs: ["popping-isolation", "popping-arm-wave"], bpm: 65)
        try expect(!prepared.warnings.contains { $0.contains("未包含") }, "Included prerequisite acknowledged")
        try expect(prepared.warnings.contains { $0.contains("熟练度") }, "Selection does not imply mastery")
        for bpm in [Double.nan, .infinity, -.infinity, 0, 39.9, 201] {
            try expectError(SequenceError.invalidBPM) {
                _ = try SequenceBuilder.make(moveIDs: ["hiphop-bounce"], bpm: bpm)
            }
        }
        try expectError(SequenceError.noMoves) { _ = try SequenceBuilder.make(moveIDs: [], bpm: 90) }
        try expectError(SequenceError.unknownMove("missing")) {
            _ = try SequenceBuilder.make(moveIDs: ["missing"], bpm: 90)
        }
        let floorMove = DanceMove(id: "floor", name: "Ground movement", englishName: "Ground movement", style: .hipHop,
                                  summary: "Test", cues: ["Test"], commonMistakes: [], bpmMin: 60, bpmMax: 100,
                                  suitableForStandingPractice: false)
        try expectError(SequenceError.noEligibleMoves) {
            _ = try SequenceBuilder.make(moveIDs: [floorMove.id], catalog: [floorMove], bpm: 80)
        }
        let ids = ["hiphop-bounce", "hiphop-rock", "hiphop-step-touch", "locking-point"]
        let seeded = try SequenceBuilder.make(moveIDs: ids, bpm: 90, seed: Int.min)
        let repeated = try SequenceBuilder.make(moveIDs: ids, bpm: 90, seed: Int.min)
        try expect(seeded == repeated, "Reproducible sequence at minimum Int seed")
        let data = try JSONEncoder().encode(seeded)
        let restored = try JSONDecoder().decode(DanceSequence.self, from: data)
        try expect(restored == seeded, "Sequence JSON round trip")
    }

    private static func date(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

    private static func clockPlan() -> TrainingPlan {
        TrainingPlan(id: "clock-probe", title: "Clock probe", blocks: [
            TrainingBlock(id: "warmup", title: "Warmup", kind: .warmup, durationSeconds: 10, cue: ""),
            TrainingBlock(id: "drill", title: "Drill", kind: .drill, durationSeconds: 20, cue: ""),
            TrainingBlock(id: "rest", title: "Rest", kind: .rest, durationSeconds: 5, cue: ""),
            TrainingBlock(id: "cooldown", title: "Cooldown", kind: .cooldown, durationSeconds: 5, cue: "")
        ])
    }

    private static func clocks() throws {
        do {
            var clock = TrainingClock(plan: clockPlan())
            try expect(clock.start(at: date(0)), "Start idle clock")
            try expect(!clock.start(at: date(5)), "Duplicate start ignored")
            try expect(!clock.tick(at: date(7)), "Seven seconds is not completion")
            try expect(clock.pause(at: date(8)), "Running clock pauses")
            try expect(clock.activeSeconds == 8, "Pause credits pre-pause time")
            try expect(clock.snapshot(at: date(100)).activeSeconds == 8, "Pause excludes time")
            try expect(clock.snapshot(at: date(100)).remainingSeconds == 2, "Paused remainder stable")
            try expect(!clock.tick(at: date(100)), "Paused tick cannot complete")
            try expect(clock.resume(at: date(108)), "Paused clock resumes")
            try expect(!clock.tick(at: date(113)), "Tick crosses first block")
            try expect(clock.currentBlockIndex == 1 && clock.remainingSeconds == 17 && clock.activeSeconds == 13, "Cross-block accounting")
            try expect(clock.tick(at: date(1_000)), "Late tick completes once")
            try expect(clock.state == .completed && clock.activeSeconds == 40 && clock.completedBlocks == 4, "Late tick capped at plan end")
            try expect(clock.finishedAt == date(140), "Exact end includes pause but excludes timer delay")
            try expect(!clock.tick(at: date(2_000)), "No repeated completion event")
            try expect(!clock.advance(at: date(2_001)), "No advance after completion")
            try expect(!clock.start(at: date(2_001)), "No restart after completion")
            let first = try require(clock.finishedSession(), "Completed session available")
            let second = try require(clock.finishedSession(), "Repeated session read available")
            try expect(first.id == second.id, "Stable history ID permits deduplication")
            try expect(first.activeSeconds == 40 && first.completedBlocks == 4, "Accurate completed history")
        }
        do {
            var clock = TrainingClock(plan: clockPlan())
            clock.start(at: date(0))
            try expect(!clock.advance(at: date(5)), "Skip first block without ending whole plan")
            try expect(clock.activeSeconds == 5 && clock.currentBlockIndex == 1 && clock.completedBlocks == 0, "Skipped time and block not credited")
            clock.tick(at: date(25))
            try expect(clock.currentBlockIndex == 2 && clock.completedBlocks == 1, "Natural second block credited")
            clock.pause(at: date(25))
            try expect(!clock.advance(at: date(200)), "Skip while paused")
            try expect(clock.state == .paused && clock.currentBlockIndex == 3 && clock.activeSeconds == 25, "Skip preserves pause and actual time")
            clock.resume(at: date(250))
            try expect(clock.tick(at: date(255)), "Final unskipped block completes")
            let session = try require(clock.finishedSession(), "Skipped session history available")
            try expect(session.activeSeconds == 30 && session.completedBlocks == 2 && session.totalBlocks == 4, "No invented skipped work in history")
        }
        do {
            var clock = TrainingClock(plan: clockPlan())
            clock.start(at: date(0))
            let preview = clock.snapshot(at: date(12.5))
            try expect(preview.blockIndex == 1 && preview.remainingSeconds == 17.5 && preview.activeSeconds == 12.5, "Fractional snapshot projection")
            try expect(preview.completedBlocks == 1 && preview.remainingPlanSeconds == 27.5, "Projected aggregate time")
            try expect(clock.activeSeconds == 0 && clock.currentBlockIndex == 0, "Snapshot does not mutate clock")
            clock.tick(at: date(12.5))
            try expect(clock.snapshot(at: date(12.5)) == preview, "Tick matches projected snapshot")
        }
        do {
            var clock = TrainingClock(plan: clockPlan())
            try expect(clock.finishedSession() == nil, "No history before start")
            try expect(!clock.resume(at: date(0)), "Cannot resume idle clock")
            clock.start(at: date(0))
            try expect(clock.finishedSession() == nil, "No history while running")
            try expect(clock.stop(at: date(12.25)), "Early stop accepted")
            try expect(clock.state == .stopped, "Stopped state retained")
            try expect(!clock.resume(at: date(20)) && !clock.stop(at: date(20)) && !clock.tick(at: date(100)), "Stopped clock cannot resume or duplicate stop")
            let session = try require(clock.finishedSession(perceivedEffort: 6), "Stopped session history")
            try expect(session.activeSeconds == 12.25 && session.completedBlocks == 1 && session.perceivedEffort == 6, "Actual early-stop history")
            try expect(clock.finishedSession(perceivedEffort: 20)?.perceivedEffort == nil, "Invalid effort excluded")
        }
        do {
            var clock = TrainingClock(plan: clockPlan())
            clock.start(at: date(0))
            clock.tick(at: date(8))
            clock.tick(at: date(4))
            clock.tick(at: date(8))
            try expect(clock.activeSeconds == 8, "Backward/repeated time not credited")
            clock.tick(at: date(9))
            try expect(clock.activeSeconds == 9 && clock.remainingSeconds == 1, "Only new forward time credited")
        }
        do {
            var clock = TrainingClock(plan: clockPlan())
            clock.start(at: date(0))
            try expect(clock.pause(at: date(10)), "Pause at block boundary")
            try expect(clock.currentBlockIndex == 1 && clock.completedBlocks == 1 && clock.remainingSeconds == 20, "Boundary block credited once")
            clock.stop(at: date(100))
            try expect(clock.activeSeconds == 10 && clock.completedBlocks == 1, "Stopping paused session preserves actual progress")
        }
        do {
            var clock = TrainingClock(plan: clockPlan())
            clock.start(at: date(0))
            try expect(!clock.pause(at: date(45)), "Pause cannot replace natural completion")
            try expect(clock.state == .completed && clock.finishedAt == date(40) && clock.activeSeconds == 40, "Completion wins pause boundary")
        }
    }

    private static func persistence() throws {
        let plan = try PlanBuilder.make(durationMinutes: 15, style: .house)
        let encodedPlan = try JSONEncoder().encode(plan)
        let restoredPlan = try JSONDecoder().decode(TrainingPlan.self, from: encodedPlan)
        try expect(restoredPlan == plan, "Plan persistence")
        let session = FinishedSession(date: date(100), planTitle: plan.title, activeSeconds: 31.25,
                                      completedBlocks: 1, totalBlocks: plan.blocks.count, perceivedEffort: 4)
        let encodedSession = try JSONEncoder().encode(session)
        let restoredSession = try JSONDecoder().decode(FinishedSession.self, from: encodedSession)
        try expect(restoredSession == session, "Session persistence retains fractional actual time")
        try tempoMath()
        for invalidEffort in [-1, 0, 11, Int.max] {
            let invalid = FinishedSession(planTitle: "Test", activeSeconds: 1, completedBlocks: 0,
                                          totalBlocks: 1, perceivedEffort: invalidEffort)
            try expect(invalid.perceivedEffort == nil, "Invalid effort \(invalidEffort) not stored")
        }
    }

    private static func tempo() throws {
        let fps = 100.0
        // A bare click has no hi-hat, so the estimate may land on the beat or its half.
        // Integer frame periods keep rounding from inventing a third cycle.
        for bpm in [75.0, 80, 100, 120, 125, 150] {
            let estimate = try TempoEstimator.estimate(onsetEnvelope: clicks(bpm: bpm, fps: fps, seconds: 24), framesPerSecond: fps)
            let ratio = estimate.bpm / bpm
            let octave = abs(ratio - 1) < 0.02 || abs(ratio - 0.5) < 0.02 || abs(ratio - 2) < 0.02
            try expect(octave, "Bare click \(bpm) estimated as \(estimate.bpm), not the beat or its double")
            try expect(estimate.level == .high, "Clean click train was not high confidence")
        }
        // Eighth-note onsets stand in for a hi-hat and pick the quarter note rather than half time.
        for bpm in [80.0, 100, 120, 150] {
            var hatted = clicks(bpm: bpm, fps: fps, seconds: 24)
            let eighth = 60 / (bpm * 2) * fps
            var cursor = eighth
            while Int(cursor.rounded()) < hatted.count {
                hatted[Int(cursor.rounded())] = 0.45
                cursor += eighth
            }
            let estimate = try TempoEstimator.estimate(onsetEnvelope: hatted, framesPerSecond: fps)
            try expect(abs(estimate.bpm - bpm) < 1, "Hi-hat grid \(bpm) estimated as \(estimate.bpm)")
        }
        // A dotted 3:2 grid must not drag a 4/4 pulse onto the triplet.
        let straight = clicks(bpm: 120, fps: fps, seconds: 24)
        var dotted = straight
        let triplet = 60 / 180.0 * fps
        var cursor = 0.0
        while Int(cursor) < dotted.count { dotted[Int(cursor)] += 0.35; cursor += triplet }
        let mixed = try TempoEstimator.estimate(onsetEnvelope: dotted, framesPerSecond: fps)
        try expect(abs(mixed.bpm - 120) < 1, "Dotted grid pulled 120 BPM to \(mixed.bpm)")

        try expectError(TempoEstimationError.invalidInput) { _ = try TempoEstimator.estimate(onsetEnvelope: [1, .nan], framesPerSecond: fps) }
        try expectError(TempoEstimationError.invalidInput) { _ = try TempoEstimator.estimate(onsetEnvelope: [1, 1], framesPerSecond: 0) }
        try expectError(TempoEstimationError.tooShort) { _ = try TempoEstimator.estimate(onsetEnvelope: clicks(bpm: 120, fps: fps, seconds: 3), framesPerSecond: fps) }
        try expectError(TempoEstimationError.noPeriodicity) {
            _ = try TempoEstimator.estimate(onsetEnvelope: Array(repeating: 0, count: Int(fps * 16)), framesPerSecond: fps)
        }
        let restored = try JSONDecoder().decode(TempoEstimate.self, from: JSONEncoder().encode(TempoEstimate(bpm: 96, confidence: 0.4)))
        try expect(restored.bpm == 96 && restored.level == .high, "Tempo estimate did not round-trip")
        try expect(TempoConfidence(0.2) == .medium && TempoConfidence(0.05) == .low, "Confidence bands moved")
    }

    private static func tempoMath() throws {
        try expect(MotionTempo.clampSpeed(.nan) == 1 && MotionTempo.clampSpeed(3) == 2 && MotionTempo.clampSpeed(0.1) == 0.25, "Speed clamp")
        try expect(MotionTempo.clampBeat(.nan) == 90 && MotionTempo.clampBeat(10) == 40 && MotionTempo.clampBeat(400) == 180, "Beat clamp")
        try expect(MotionTempo.isValidTrackBPM(30) && MotionTempo.isValidTrackBPM(300) && !MotionTempo.isValidTrackBPM(29) && !MotionTempo.isValidTrackBPM(.infinity), "Track BPM bounds")
        try expect(MotionTempo.speed(motionBPM: 80, targetBPM: 120) == 1.5, "Motion speed is target / recorded")
        try expect(MotionTempo.speed(motionBPM: 50, targetBPM: 200) == 2, "Unreachable tempo clamps to 2×")
        try expect(MotionTempo.canReach(motionBPM: 80, targetBPM: 120) && !MotionTempo.canReach(motionBPM: 50, targetBPM: 200), "Reachability")
        try expect(MotionTempo.speed(motionBPM: 0, targetBPM: 100) == nil && MotionTempo.musicTarget(trackBPM: .nan, rate: 1, multiplier: .single) == nil, "Unusable tempos stay absent")
        try expect(MotionTempo.musicTarget(trackBPM: 100, rate: 0.75, multiplier: .double) == 150, "Music tempo is BPM × rate × multiple")
        try expect(BeatMultiplier.double.rawValue == 2 && BeatMultiplier.quarter.summary == "四拍一动", "Beat multiples")
        for speed in [0.25, 1.1, 2.0] {
            _ = try AISTPracticeReference(sequence: tempoSequence(), name: "x", startFrame: 0, endFrame: 1, optimized: true, speed: speed)
        }
        for speed in [0.0, 0.24, 2.01, Double.nan] {
            try expectError(AISTPracticeError.invalidSpeed) {
                _ = try AISTPracticeReference(sequence: tempoSequence(), name: "x", startFrame: 0, endFrame: 1, optimized: true, speed: speed)
            }
        }
    }

    private static func party() throws {
        let frames = [
            PartyFrame(kind: .control, payload: Data("{\"type\":\"stop\"}".utf8)),
            PartyFrame(kind: .video, payload: Data((0..<5_000).map { UInt8($0 & 0xFF) })),
            PartyFrame(kind: .control, payload: Data())
        ]
        let stream = frames.map { $0.encoded() }.reduce(Data(), +)
        for chunk in [1, 3, 7, 64, 4_096, stream.count] {
            var decoder = PartyFrameDecoder()
            var received: [PartyFrame] = []
            var cursor = stream.startIndex
            while cursor < stream.endIndex {
                let end = min(cursor + chunk, stream.endIndex)
                received += try decoder.append(stream[cursor..<end])
                cursor = end
            }
            try expect(received == frames && decoder.bufferedByteCount == 0, "Frames survive \(chunk)-byte chunking")
        }
        var oversize = PartyFrameDecoder()
        var header = Data(); header.appendBigEndian(UInt32(PartyProtocol.maxFrameLength + 1))
        try expectError(PartyFrameError.frameTooLarge(PartyProtocol.maxFrameLength + 1)) { _ = try oversize.append(header) }
        var empty = PartyFrameDecoder()
        try expectError(PartyFrameError.emptyFrame) { _ = try empty.append(Data([0, 0, 0, 0])) }
        var unknown = PartyFrameDecoder()
        try expectError(PartyFrameError.unknownKind(9)) { _ = try unknown.append(Data([0, 0, 0, 2, 9, 1])) }
        var partial = PartyFrameDecoder()
        try expect(try partial.append(Data([0, 0, 0, 3, 1, 0x7B])).isEmpty && partial.bufferedByteCount == 6, "Incomplete frame waits for more bytes")

        let pose = PartyPose(observation: LivePoseObservation(frameNumber: 3, timestamp: 0.1, width: 640, height: 480, bodyCount: 1, joints: [
            "nose": LivePosePoint(x: 0.5, y: 0.9, confidence: 0.8), "bad": LivePosePoint(x: .nan, y: 0.5, confidence: 0.5)
        ]))
        try expect(pose.joints.count == 1 && pose.observation.joints["nose"]?.confidence == 0.8 && pose.observation.width == 640, "Pose keeps finite joints only")
        let messages: [PartyMessage] = [
            .hello(PartyHello(peerID: "a", name: "A", appVersion: "0.5.0")),
            .welcome(PartyWelcome(peerID: "b", name: "B", appVersion: "0.5.0")),
            .rejected(PartyRejection(reason: "full")),
            .ping(PartyPing(id: 7, sentAt: 12.5)),
            .pong(PartyPong(id: 7, sentAt: 12.5, receivedAt: 20, repliedAt: 20.001)),
            .sharing(PartySharing(mode: .video, width: 640, height: 360)),
            .pose(pose),
            .beat(PartyBeatState(bpm: 96, playing: true, sourceName: "Club beat", isTrack: false, barAnchor: 100)),
            .beat(PartyBeatState(bpm: nil, playing: false, sourceName: "Song", isTrack: true, barAnchor: nil)),
            .countdown(PartyCountdown(startsAt: 130, bpm: 96, sourceName: "Club beat")),
            .stop,
            .bye(PartyFarewell(reason: nil))
        ]
        for message in messages {
            let data = try message.encoded()
            let object = try require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "Message is a JSON object")
            try expect(object["type"] as? String == message.typeName, "Type tag for \(message.typeName)")
            try expect(try PartyMessage(jsonData: data) == message, "Round trip for \(message.typeName)")
        }
        try expectError(PartyMessageError.unknownType("dance-battle")) {
            _ = try PartyMessage(jsonData: Data("{\"type\":\"dance-battle\",\"body\":{}}".utf8))
        }

        let packet = PartyVideoPacket(timestamp: 1.25, width: 960, height: 540, isKeyframe: true,
                                      parameterSets: [Data([0x67, 0x42, 0x00]), Data([0x68, 0xCE])], data: Data(repeating: 0xAB, count: 1_000))
        let encoded = packet.encoded()
        try expect(try PartyVideoPacket(decoding: encoded) == packet && packet.frame().kind == .video, "Video packet round trip")
        let delta = PartyVideoPacket(timestamp: 1.3, width: 960, height: 540, isKeyframe: false, parameterSets: [], data: Data([1, 2, 3]))
        try expect(try PartyVideoPacket(decoding: delta.encoded()) == delta, "Delta packet round trip")
        for cut in [0, 1, 5, 13, 20, encoded.count - 1] {
            try expect((try? PartyVideoPacket(decoding: encoded.prefix(cut))) == nil, "Truncated packet at \(cut) rejected")
        }
        try expectError(PartyVideoPacketError.truncated) { _ = try PartyVideoPacket(decoding: encoded + Data([0])) }
        var wrongVersion = encoded; wrongVersion[wrongVersion.startIndex] = 9
        try expectError(PartyVideoPacketError.unsupportedVersion(9)) { _ = try PartyVideoPacket(decoding: wrongVersion) }
        let zero = PartyVideoPacket(timestamp: 0, width: 0, height: 0, isKeyframe: false, parameterSets: [], data: Data([1]))
        try expectError(PartyVideoPacketError.invalidDimensions) { _ = try PartyVideoPacket(decoding: zero.encoded()) }

        var sync = PartyClockSync(capacity: 4)
        try expect(sync.offset == nil, "No offset before samples")
        sync.record(sentAt: 0, remoteReceivedAt: 100.010, remoteRepliedAt: 100.012, receivedAt: 0.022)
        try expect(abs((sync.offset ?? 0) - 100) < 1e-9 && abs((sync.roundTrip ?? 0) - 0.020) < 1e-9, "Symmetric sample gives the exact offset")
        sync.record(sentAt: 1, remoteReceivedAt: 101.300, remoteRepliedAt: 101.301, receivedAt: 1.320)
        try expect(abs((sync.offset ?? 0) - 100) < 1e-9, "Jittery sample loses to the quieter one")
        try expect(abs((sync.localTime(forRemote: 150) ?? 0) - 50) < 1e-9 && abs((sync.remoteTime(forLocal: 50) ?? 0) - 150) < 1e-9, "Clock conversions")
        try expect(sync.record(sentAt: 5, remoteReceivedAt: 105, remoteRepliedAt: 105, receivedAt: 4) == nil, "Receive before send rejected")
        try expect(sync.record(sentAt: 5, remoteReceivedAt: .nan, remoteRepliedAt: 105, receivedAt: 6) == nil, "Non-finite sample rejected")
        for i in 0..<10 { sync.record(sentAt: Double(i), remoteReceivedAt: Double(i) + 100.05, remoteRepliedAt: Double(i) + 100.05, receivedAt: Double(i) + 0.1) }
        try expect(sync.samples.count == 4 && abs((sync.offset ?? 0) - 100) < 1e-9, "Bounded sample window keeps the best offset")

        try expect(PartyBeatGrid.barLength(bpm: 120) == 4, "Eight counts at 120 BPM last 4 s")
        try expect(PartyBeatGrid.nextBarStart(after: 11, anchor: 10, bpm: 120) == 14, "Next bar after 11 s")
        try expect(PartyBeatGrid.nextBarStart(after: 14, anchor: 10, bpm: 120) == 14, "Bar boundary itself counts")
        try expect(PartyBeatGrid.nextBarStart(after: 13.9, anchor: 10, bpm: 120, minimumLead: 0.15) == 18, "Minimum lead skips a too-close bar")
        try expect(PartyBeatGrid.nextBarStart(after: 3, anchor: 10, bpm: 120) == 6, "Grid extends before the anchor")
        try expect(PartyBeatGrid.nextBarStart(after: 1, anchor: 0, bpm: 0) == nil && PartyBeatGrid.nextBarStart(after: 1, anchor: 0, bpm: 120, minimumLead: -1) == nil, "Invalid grid input")
        try expect(PartyBeatGrid.beatIndex(at: 10.6, anchor: 10, bpm: 120) == 1 && PartyBeatGrid.beatIndex(at: 14.1, anchor: 10, bpm: 120) == 0 && PartyBeatGrid.beatIndex(at: 9, anchor: 10, bpm: 120) == nil, "Beat index within the bar")

        try expect(PartyAddress.parse(" 192.168.1.8:52000 ") == PartyAddress(host: "192.168.1.8", port: 52000), "IPv4 address")
        try expect(PartyAddress.parse("[fe80::1%en0]:7000") == PartyAddress(host: "fe80::1%en0", port: 7000), "Bracketed IPv6 address")
        try expect(PartyAddress.parse("bens-mac.local:1") == PartyAddress(host: "bens-mac.local", port: 1), "Host name")
        try expect(PartyAddress(host: "fe80::1", port: 5).description == "[fe80::1]:5" && PartyAddress(host: "10.0.0.2", port: 5).description == "10.0.0.2:5", "Address formatting")
        for bad in ["", "192.168.1.8", "192.168.1.8:", ":5000", "192.168.1.8:0", "192.168.1.8:65536", "a b:5", "fe80::1:5000", "[fe80::1]5000", "[]:5000", "host:12ab"] {
            try expect(PartyAddress.parse(bad) == nil, "Rejected address \(bad)")
        }
        let code = PartyRoomCode.generate()
        try expect(code.count == 4 && PartyRoomCode.normalize(code) == code, "Generated code is four digits")
        try expect(PartyRoomCode.normalize(" 12-34 ") == "1234", "Separators tolerated in a code")
        for bad in ["123", "12345", "12a4", "１２３４"] { try expect(PartyRoomCode.normalize(bad) == nil, "Rejected code \(bad)") }
        try expect(PartyShareMode.off.sendsPose == false && PartyShareMode.skeleton.sendsPose && !PartyShareMode.skeleton.sendsVideo && PartyShareMode.video.sendsVideo, "Share modes")
    }

    /// One sample at each beat, long enough for the slowest accepted period.
    private static func clicks(bpm: Double, fps: Double, seconds: Double) -> [Double] {
        let count = Int(fps * seconds)
        var envelope = [Double](repeating: 0, count: count)
        let step = 60 / bpm * fps
        var cursor = 0.0
        while Int(cursor.rounded()) < count {
            envelope[Int(cursor.rounded())] = 1
            cursor += step
        }
        return envelope
    }

    /// AISTPracticeReference checks frame count, fps and speed. Paths are not opened.
    private static func tempoSequence() -> AISTSequence {
        let json = """
        {"id":"gMH_sBM_cAll_d01_mMH0_ch01","genreCode":"gMH","genreName":"Hip-hop","dancerID":"d01","musicID":"mMH0","frameCount":8,"fps":60,"rawPath":"sequences/gMH_sBM_cAll_d01_mMH0_ch01.raw.f64","optimizedPath":"sequences/gMH_sBM_cAll_d01_mMH0_ch01.optimized.f64","byteCount":3264,"ignored":false}
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(AISTSequence.self, from: json)
    }
}
