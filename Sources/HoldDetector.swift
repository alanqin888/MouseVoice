import Foundation

/// Pure state machine: distances are Quartz screen points, time is monotonic seconds.
struct HoldDetector {
    enum State: Equatable { case idle, pending, active, cancelled }
    enum Action: Equatable { case none, begin, end }
    var delay: Double
    var tolerance: Double
    private(set) var state: State = .idle
    private var origin = CGPoint.zero
    private var started: Double = 0

    init(delay: Double, tolerance: Double) {
        self.delay = delay
        self.tolerance = tolerance
    }

    mutating func down(at point: CGPoint, now: Double) {
        origin = point
        started = now
        state = .pending
    }

    mutating func move(to point: CGPoint) -> Action {
        guard state == .pending || state == .active else { return .none }
        if hypot(point.x - origin.x, point.y - origin.y) > tolerance {
            let wasActive = state == .active
            state = .cancelled // Never re-arm until another down, even if the pointer returns.
            return wasActive ? .end : .none
        }
        return .none
    }

    mutating func deadline(now: Double, buttonDown: Bool, point: CGPoint) -> Action {
        guard buttonDown else { return reset() }
        let action = move(to: point)
        if action == .end { return action }
        if state == .pending && now - started >= delay {
            state = .active
            return .begin
        }
        return .none
    }

    mutating func reset() -> Action {
        let wasActive = state == .active
        state = .idle
        return wasActive ? .end : .none
    }
}
