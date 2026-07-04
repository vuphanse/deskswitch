import DeskSwitchCore
import UserNotifications

/// Real macOS notifications. Requires an app bundle (UNUserNotificationCenter
/// asserts without one), hence lives in the executable and is only used in app mode.
final class UserNotifier: Notifier {
    init() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert]) { _, _ in }
    }

    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
