import Foundation

/// A coaching day ends after a completed night, including a night that starts after midnight.
public enum CoachConversationBoundary {
    /// Without a recorded night, retire only after a long inactive gap rather than guessing at midnight.
    public static let maximumIdleSeconds = 36 * 3_600

    public static func shouldRetire(lastMessage: Int?, now: Int,
                                   sleepWindows: [(start: Int, end: Int)]) -> Bool {
        guard let lastMessage, now > lastMessage else { return false }
        let minimumNightSeconds = Int(DietDayBoundary.minimumNightHours * 3_600)
        let wokeSinceMessage = TimeWindows.merged(sleepWindows.filter { $0.end <= now }).contains {
            $0.end > lastMessage && $0.end - $0.start >= minimumNightSeconds
        }
        return wokeSinceMessage || now - lastMessage >= maximumIdleSeconds
    }
}
