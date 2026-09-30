import Foundation

// MARK: - Interval merging
//
// Exists for one specific correctness problem: steps taken during a workout must be removed from the
// NEAT total exactly once. Workouts can overlap — a strap-detected bout and a manually logged session
// covering the same hour, or a warm-up bleeding into the main set — and counting a shared minute twice
// would subtract more steps than the day contained, silently deflating the eating budget.
//
// `Repository.workoutRows` already dedups cross-source twins by natural key. This handles the case that
// survives that: two genuinely distinct rows whose time ranges happen to intersect.

public enum TimeWindows {

    /// Half-open windows as unix seconds, merged so no second is covered twice.
    ///
    /// Touching windows are merged too (`end == nextStart`): the boundary second belongs to one of them,
    /// and keeping them separate only creates an opportunity to count it twice later.
    ///
    /// Invalid windows (`end <= start`) are dropped rather than repaired — a zero-length workout has no
    /// steps to attribute, and guessing at its intended span would be inventing data.
    public static func merged(_ windows: [(start: Int, end: Int)]) -> [(start: Int, end: Int)] {
        let valid = windows.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard var current = valid.first else { return [] }
        var out: [(start: Int, end: Int)] = []
        for w in valid.dropFirst() {
            if w.start <= current.end {
                current.end = max(current.end, w.end)
            } else {
                out.append(current)
                current = w
            }
        }
        out.append(current)
        return out
    }

    /// Total seconds covered by the merged windows — the honest span, counting no second twice.
    public static func coveredSeconds(_ windows: [(start: Int, end: Int)]) -> Int {
        merged(windows).reduce(0) { $0 + ($1.end - $1.start) }
    }
}
