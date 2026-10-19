import Foundation
import UserNotifications

// Notifications with one-click fixes: heat and updates

final class Alerts: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onAction: ((String, [AnyHashable: Any]) -> Void)?

    override init() {
        super.init()
        center.delegate = self
        let cap = UNNotificationAction(identifier: "cap", title: "Cap")
        let idle = UNNotificationAction(identifier: "idle", title: "Idle it")
        let wake = UNNotificationAction(identifier: "wake", title: "Wake")
        center.setNotificationCategories([UNNotificationCategory(identifier: "heat", actions: [cap, idle], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: "memory", actions: [idle], intentIdentifiers: []),
                                          UNNotificationCategory(identifier: "autoIdle", actions: [wake], intentIdentifiers: [])])
    }

    // macOS asks once; once allowed, done runs straight away
    func ask(then done: (() -> Void)? = nil) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted, let done { DispatchQueue.main.async(execute: done) }
        }
    }

    func post(_ id: String, title: String, body: String, category: String = "", info: [String: Any] = [:]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.userInfo = info
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id + "-\(Date().timeIntervalSince1970)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async { self.onAction?(action, info) }
        completionHandler()
    }
}
