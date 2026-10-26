import Foundation
import UserNotifications

/// The weekly digests and alerts as iPhone notifications. Local notifications work with a free
/// Apple ID; true server push (APNs) needs the paid developer program, so it's a next step.
enum LocalNotifications {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func post(title: String, body: String, after seconds: TimeInterval = 1, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = AIMarkdown.plain(body)  // the lock screen can't show **bold**
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func scheduleWeekly(id: String, weekday: Int, hour: Int, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = AIMarkdown.plain(body)  // the lock screen can't show **bold**
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, weekday: weekday), repeats: true)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel(_ ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// More → Notifications. Stored on the phone (UserDefaults); applied to LocalNotifications.
enum NotificationPrefs {
    static let spendingKey = "notifySpending"
    static let investmentKey = "notifyInvestment"
    static let overBudgetKey = "notifyOverBudget"
    static let salaryKey = "notifySalary"
    static let weekdayKey = "digestWeekday"   // 1 = Sunday … 7 = Saturday
    static let hourKey = "digestHour"

    private static var defaults: UserDefaults { .standard }
    private static func on(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }

    static func timeLabel(weekday: Int, hour: Int) -> String {
        "\(Calendar.current.weekdaySymbols[max(0, min(6, weekday - 1))])s \(hourLabel(hour))"
    }

    static func hourLabel(_ h: Int) -> String { "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")" }

    /// The weekly reminders, at the chosen day and time (repeat every week until switched off).
    static func applySchedule() {
        let weekday = defaults.object(forKey: weekdayKey) as? Int ?? 1
        let hour = defaults.object(forKey: hourKey) as? Int ?? 18
        LocalNotifications.cancel(["weekly-spending", "weekly-investment"])
        if on(spendingKey) {
            LocalNotifications.scheduleWeekly(id: "weekly-spending", weekday: weekday, hour: hour,
                                              title: "Your weekly spending check-in",
                                              body: "See how your pockets did this week in One Finance.")
        }
        if on(investmentKey) {
            LocalNotifications.scheduleWeekly(id: "weekly-investment", weekday: weekday, hour: hour,
                                              title: "Your weekly investment check-in",
                                              body: "See how your portfolio moved this week in One Finance.")
        }
    }

    /// Over-budget and "salary not received" alerts, at most once per pocket (or salary) per month.
    static func checkAlerts(month: String, overPockets: [String], salaryMissing: Bool) {
        if on(overBudgetKey) {
            for name in overPockets {
                let key = "alerted-over-\(month)-\(name)"
                guard !defaults.bool(forKey: key) else { continue }
                defaults.set(true, forKey: key)
                LocalNotifications.post(title: "\(name) is over budget", body: "You've spent more than this month's \(name) budget. Open Wallet to move money from another pocket.",
                                        id: key)
            }
        }
        if on(salaryKey), salaryMissing {
            let key = "alerted-salary-\(month)"
            if !defaults.bool(forKey: key) {
                defaults.set(true, forKey: key)
                LocalNotifications.post(title: "Salary not received yet", body: "Your salary hasn't arrived this month. Check with your employer or your bank.", id: key)
            }
        }
    }
}
