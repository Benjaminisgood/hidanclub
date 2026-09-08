import Foundation

public enum TrainingClockState: String, Codable, Sendable {
    case idle, running, paused, completed, stopped
}

public struct TrainingSnapshot: Sendable, Equatable {
    public let state: TrainingClockState
    /// Remaining seconds in the current block, with fractional precision.
    public let remainingSeconds: Double
    /// Time spent running, including scheduled rest and excluding pauses/skipped time.
    public let activeSeconds: Double
    public let blockIndex: Int
    /// Only blocks whose full remaining duration elapsed count as completed.
    public let completedBlocks: Int
    public let totalBlocks: Int
    public let isCompleted: Bool
    public let remainingPlanSeconds: Double
    public let currentBlock: TrainingBlock?
}

/// A deterministic value-type clock. Drive `tick(at:)` from the UI's timer and
/// inject dates in tests. Mutations are intended to be owned by a single actor.
public struct TrainingClock: Sendable {
    public let plan: TrainingPlan
    public let sessionID: UUID
    public private(set) var state: TrainingClockState = .idle
    public private(set) var currentBlockIndex: Int = 0
    public private(set) var elapsedBlockSeconds: Double = 0
    public private(set) var activeSeconds: Double = 0
    public private(set) var completedBlocks: Int = 0
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    private var lastRunningAt: Date?

    public init(plan: TrainingPlan, sessionID: UUID = UUID()) {
        self.plan = plan
        self.sessionID = sessionID
    }

    public var isCompleted: Bool { state == .completed }
    public var currentBlock: TrainingBlock? {
        plan.blocks.indices.contains(currentBlockIndex) ? plan.blocks[currentBlockIndex] : nil
    }
    public var remainingSeconds: Double {
        max(0, Double(currentBlock?.durationSeconds ?? 0) - elapsedBlockSeconds)
    }
    public var remainingPlanSeconds: Double {
        guard currentBlock != nil else { return 0 }
        return remainingSeconds + plan.blocks.dropFirst(currentBlockIndex + 1).reduce(0) {
            $0 + max(0, Double($1.durationSeconds))
        }
    }

    /// Starts an idle clock only. A completed/stopped clock cannot accidentally restart.
    @discardableResult
    public mutating func start(at date: Date = Date()) -> Bool {
        guard state == .idle else { return false }
        startedAt = date
        lastRunningAt = date
        if plan.blocks.isEmpty {
            finish(at: date)
        } else {
            state = .running
        }
        return true
    }

    @discardableResult
    public mutating func pause(at date: Date = Date()) -> Bool {
        guard state == .running else { return false }
        _ = tick(at: date)
        guard state == .running else { return false }
        state = .paused
        lastRunningAt = nil
        return true
    }

    @discardableResult
    public mutating func resume(at date: Date = Date()) -> Bool {
        guard state == .paused else { return false }
        state = .running
        lastRunningAt = date
        return true
    }

    /// Returns true only on the call that transitions to natural completion.
    /// A late UI timer catches up across any number of blocks and never counts
    /// time beyond the actual end of the plan.
    @discardableResult
    public mutating func tick(at date: Date = Date()) -> Bool {
        guard state == .running, let previousDate = lastRunningAt, date >= previousDate else { return false }
        var unconsumed = date.timeIntervalSince(previousDate)
        var consumed = 0.0
        while currentBlock != nil {
            let remaining = remainingSeconds
            if unconsumed < remaining {
                elapsedBlockSeconds += unconsumed
                activeSeconds += unconsumed
                lastRunningAt = date
                return false
            }
            // Handles zero-duration blocks from externally decoded plans too.
            unconsumed -= remaining
            consumed += remaining
            activeSeconds += remaining
            completedBlocks += 1
            currentBlockIndex += 1
            elapsedBlockSeconds = 0
            if currentBlock == nil {
                finish(at: previousDate.addingTimeInterval(consumed))
                return true
            }
        }
        lastRunningAt = date
        return false
    }

    /// Skips the current block. Skipped duration and the skipped block are not
    /// credited to the history. If paused, the next block remains paused.
    @discardableResult
    public mutating func advance(at date: Date = Date()) -> Bool {
        guard state == .running || state == .paused else { return false }
        if state == .running, tick(at: date) { return true }
        guard currentBlock != nil else { return false }
        currentBlockIndex += 1
        elapsedBlockSeconds = 0
        if currentBlock == nil {
            finish(at: date)
            return true
        }
        if state == .running { lastRunningAt = max(lastRunningAt ?? date, date) }
        return false
    }

    /// Ends a running or paused session, preserving the actual elapsed amount.
    @discardableResult
    public mutating func stop(at date: Date = Date()) -> Bool {
        guard state == .running || state == .paused else { return false }
        if state == .running { _ = tick(at: date) }
        if state == .completed { return true }
        state = .stopped
        finishedAt = max(date, lastRunningAt ?? date)
        lastRunningAt = nil
        return true
    }

    /// Projects the clock to a date without mutating the original. Call `tick`
    /// before persisting completion so state and history advance together.
    public func snapshot(at date: Date = Date()) -> TrainingSnapshot {
        var projected = self
        _ = projected.tick(at: date)
        return TrainingSnapshot(state: projected.state, remainingSeconds: projected.remainingSeconds,
                                activeSeconds: projected.activeSeconds, blockIndex: projected.currentBlockIndex,
                                completedBlocks: projected.completedBlocks, totalBlocks: plan.blocks.count,
                                isCompleted: projected.isCompleted,
                                remainingPlanSeconds: projected.remainingPlanSeconds,
                                currentBlock: projected.currentBlock)
    }

    /// The stable sessionID makes repeated reads safe to deduplicate in storage.
    /// No history is fabricated before a started session has ended.
    public func finishedSession(perceivedEffort: Int? = nil) -> FinishedSession? {
        guard startedAt != nil, let finishedAt, state == .completed || state == .stopped else { return nil }
        return FinishedSession(id: sessionID, date: finishedAt, planTitle: plan.title,
                               activeSeconds: activeSeconds, completedBlocks: completedBlocks,
                               totalBlocks: plan.blocks.count, perceivedEffort: perceivedEffort)
    }

    private mutating func finish(at date: Date) {
        state = .completed
        finishedAt = date
        lastRunningAt = nil
    }
}
