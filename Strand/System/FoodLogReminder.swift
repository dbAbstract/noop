import Foundation
import UserNotifications

// MARK: - A nudge to log what you ate
//
// Exists to protect something specific, not to nag. The engine that decides whether the diet is working
// needs ~70% intake coverage across three weeks, so a handful of forgotten days puts a verdict out of
// reach — and a day you did not log is indistinguishable from a day you did not eat.
//
// MECHANISM: a repeating `UNCalendarNotificationTrigger`, following `WindDownNudge`.
//
// Deliberately NOT the `CoachBriefScheduler` shape. That one needs a background task because it has to
// RUN CODE at fire time — it generates its message from an AI call. This has a fixed message, so the
// notification centre can fire it with the app suspended or terminated, which means no `BGTaskScheduler`
// identifier, no `#if os` branching, and no dependence on iOS deciding to wake us.
//
// THE TRADE THAT BUYS: a calendar trigger cannot ask "did they log today?" when it fires, and a repeating
// trigger is ONE pending request covering every future day — so there is no way to skip just today
// without cancelling the reminder entirely. Suppressing today properly would mean a background task, and
// on iOS that is best-effort: the reminder would then silently miss days, which is the failure that
// matters. So it fires regardless, and only an ALREADY-DELIVERED notification is cleared once food is
// logged (see `clearDeliveredIfAny`). Being occasionally reminded of something already done is a much
// smaller cost than not being reminded on the day it counted.

@MainActor
enum FoodLogReminder {

    private enum K {
        static let enabled = "noop.foodReminder.enabled"
        /// Minutes since local midnight. An Int, never a Date — the house convention shared with
        /// `windDown.wakeMinutes` and `coachBrief.timeMinutes`.
        static let time = "noop.foodReminder.timeMinutes"
    }

    /// 20:00. Late enough that the day's eating is essentially done, early enough to still act on it.
    static let defaultTimeMinutes = 20 * 60

    static let requestId = "noop-food-reminder"

    /// Matched in `NotificationPresenter` to route a tap to the food screen.
    static let notificationCategoryId = "food-reminder"

    /// What happened when the user flipped the switch. `denied` exists so the UI can revert rather than
    /// storing an "on" the OS will never honour.
    enum EnableOutcome { case scheduled, denied, off }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: K.enabled) }

    static var timeMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: K.time) as? Int ?? defaultTimeMinutes
        return min(max(raw, 0), 24 * 60 - 1)
    }

    // MARK: - Enable / schedule

    /// Enabling checks authorization FIRST and reports the outcome.
    ///
    /// `requestAuthorization` only shows the system dialog when the status is `.notDetermined`. Once a
    /// user has denied — or a previous sideload under the same bundle id did — the dialog never appears
    /// and a naive implementation schedules reminders the OS silently discards, with nothing on screen
    /// to explain the silence. So denial is surfaced and `false` is persisted.
    static func setEnabled(_ on: Bool, completion: (@MainActor (EnableOutcome) -> Void)? = nil) {
        guard on else {
            UserDefaults.standard.set(false, forKey: K.enabled)
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: [requestId])
            completion?(.off)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    UserDefaults.standard.set(true, forKey: K.enabled)
                    schedule()
                    completion?(.scheduled)
                case .notDetermined:
                    UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                            Task { @MainActor in
                                UserDefaults.standard.set(granted, forKey: K.enabled)
                                if granted { schedule() }
                                completion?(granted ? .scheduled : .denied)
                            }
                        }
                default:
                    // Denied. Persist false so no dead "on" is stored.
                    UserDefaults.standard.set(false, forKey: K.enabled)
                    completion?(.denied)
                }
            }
        }
    }

    static func setTimeMinutes(_ minutes: Int) {
        UserDefaults.standard.set(min(max(minutes, 0), 24 * 60 - 1), forKey: K.time)
        if isEnabled { schedule() }
    }

    /// (Re)arm the daily trigger. Replaces any existing one — `add` with the same identifier overwrites,
    /// so changing the time cannot leave the old hour armed as well.
    static func schedule() {
        guard isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [requestId])

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Log today's food")
        // States WHY, because a reminder that only says "do the thing" is the kind people switch off.
        content.body = String(localized: "A day you don't log is a gap in your trend, not a zero.")
        content.sound = .default
        content.categoryIdentifier = notificationCategoryId

        var comps = DateComponents()
        comps.hour = timeMinutes / 60
        comps.minute = timeMinutes % 60
        // repeats: true → lives in the notification centre rather than the process, so it keeps firing
        // daily without NOOP running.
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        center.add(UNNotificationRequest(identifier: requestId, content: content, trigger: trigger))
    }

    // MARK: - After logging

    /// Clear a reminder that has ALREADY FIRED, once food is logged.
    ///
    /// Only the delivered one. A repeating calendar trigger is a single pending request covering every
    /// future day, so removing it to skip today would cancel the reminder outright — and re-adding it
    /// on the next launch means no reminder at all on any day the app is not opened, which is precisely
    /// the day it was needed.
    ///
    /// So today's reminder still fires if you log after it. That is the deliberate trade: being
    /// occasionally reminded of something already done is a far smaller cost than silently not being
    /// reminded at all. What this does fix is the worse half — a notification sitting in Notification
    /// Centre telling you to log food you have just logged.
    static func clearDeliveredIfAny() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
    }
}
