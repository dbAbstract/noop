import Foundation
import UserNotifications

// MARK: - A nudge to weigh in, timed off waking
//
// The weigh-in is half of what `AdaptiveExpenditureEngine` needs and the half people skip: it has to happen
// in a narrow window — same time each morning, before eating — and if that window passes the day is simply
// gone. A food log can be reconstructed at 11pm; a weight cannot.
//
// SO IT RIDES THE WAKE SIGNAL, not a clock hour, for the same reason the morning brief does: the useful
// moment is "you are up and have not eaten yet", which is a property of the person rather than of the time.
//
// ONE NOTIFICATION A DAY, BETWEEN THIS AND THE BRIEF. Two notifications about the morning is worse than one
// — the second trains you to dismiss both. The brief outranks this because it carries more, so this fires
// only when the brief did not.
//
// It also does not fire when the day already has a weigh-in, which is the common case by lunchtime and
// means the reminder is self-silencing rather than something to switch off.
@MainActor
enum WeighInReminder {

    private enum K {
        static let enabled = "noop.weighInReminder.enabled"
        /// The local day this last posted, so a foreground re-check cannot re-notify.
        static let lastFiredDay = "noop.weighInReminder.lastFiredDay"
    }

    /// Matched in `NotificationPresenter` to route a tap to the weight screen.
    static let notificationCategoryId = "weigh-in-reminder"
    private static let requestId = "noop-weigh-in-reminder"

    /// Default ON. Unlike the food reminder this costs at most one notification a day, only on days the
    /// scales were not used, and it is the input whose absence silently blocks a verdict.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: K.enabled) as? Bool ?? true
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: K.enabled)
        if !on {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [requestId])
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [requestId])
        }
    }

    /// Whether a nudge is owed right now.
    ///
    /// Pure, so the decision is testable without a notification centre or a clock. Every condition is a
    /// reason NOT to fire, which is the right default for anything that interrupts.
    static func shouldFire(isEnabled: Bool,
                           hasWeighedToday: Bool,
                           wokeToday: Bool,
                           minutesSinceWake: Int?,
                           briefFiredToday: Bool,
                           lastFiredDay: String?,
                           today: String,
                           delayMinutes: Int) -> Bool {
        guard isEnabled else { return false }
        // Already done. The reminder is self-silencing — by lunchtime on a normal day it simply never
        // becomes due, which is better than a setting nobody finds.
        guard !hasWeighedToday else { return false }
        guard wokeToday, let since = minutesSinceWake, since >= delayMinutes else { return false }
        // The brief carries more and already arrived; a second notification about the same morning trains
        // the user to dismiss both.
        guard !briefFiredToday else { return false }
        guard lastFiredDay != today else { return false }
        return true
    }

    static var lastFiredDay: String? { UserDefaults.standard.string(forKey: K.lastFiredDay) }

    /// Post the nudge and record the day.
    static func fire(today: String) {
        UserDefaults.standard.set(today, forKey: K.lastFiredDay)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Step on the scales")
        // Names the COST rather than the chore. "Log your weight" is a task; a missed morning is a day the
        // trend cannot use, and that is the fact that makes it worth doing now rather than later.
        content.body = String(localized: "A weigh-in now, before you eat, is the one NOOP can use. A missed morning can't be filled in later.")
        content.sound = .default
        content.categoryIdentifier = notificationCategoryId
        // Immediate: the decision to fire has already been made by `shouldFire`, so there is nothing to
        // schedule — a trigger would only add a way for it to arrive at the wrong moment.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: requestId, content: content, trigger: nil))
    }

    /// Clear a nudge already delivered, once a weigh-in lands.
    static func clearDeliveredIfAny() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
    }
}
