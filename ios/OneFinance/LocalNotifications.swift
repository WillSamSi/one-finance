import UserNotifications

/// The weekly digests as iPhone notifications. Local notifications work with a free Apple ID;
/// true server push (APNs) needs the paid developer program, so it's a next step.
enum LocalNotifications {
    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static func post(title: String, body: String, after seconds: TimeInterval = 1) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
    }
}
