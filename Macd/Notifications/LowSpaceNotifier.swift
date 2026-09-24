import Foundation
@preconcurrency import UserNotifications

/// Fires once when free space drops below the threshold, then re-arms only after free
/// space climbs back above the threshold plus a margin, so it never flaps.
final class LowSpaceNotifier {
    static let rearmMargin: Int64 = 2_000_000_000

    private(set) var isArmed = true
    private let threshold: () -> Int64?
    private let post: (Int64) -> Void

    init(threshold: @escaping () -> Int64?, post: @escaping (Int64) -> Void) {
        self.threshold = threshold
        self.post = post
    }

    func evaluate(freeBytes: Int64?) {
        guard let limit = threshold() else {
            isArmed = true
            return
        }
        guard let free = freeBytes else { return }
        if isArmed, free < limit {
            isArmed = false
            post(free)
        } else if !isArmed, free > limit + Self.rearmMargin {
            isArmed = true
        }
    }
}

/// Posts the low-space notification and routes its tap back to the app.
final class NotificationCenterBridge: NSObject, UNUserNotificationCenterDelegate {
    nonisolated static let categoryID = "low-space"
    nonisolated static let cleanActionID = "free-up-space"

    private(set) var isAuthorized = false
    var onFreeUpSpace: () -> Void = {}

    private var center: UNUserNotificationCenter { .current() }

    func configure() {
        center.delegate = self
        let action = UNNotificationAction(identifier: Self.cleanActionID, title: "Free Up Space", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [action], intentIdentifiers: []),
        ])
        Task { await refreshAuthorization() }
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func postLowSpace(freeBytes: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "Your Mac is low on space"
        content.body = "\(Formatters.bytes(freeBytes)) left. Click to see what mac'd can safely clean."
        content.categoryIdentifier = Self.categoryID
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "low-space", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isLowSpace = response.notification.request.content.categoryIdentifier == Self.categoryID
        let dismissed = response.actionIdentifier == UNNotificationDismissActionIdentifier
        completionHandler()
        guard isLowSpace, !dismissed else { return }
        Task { @MainActor in self.onFreeUpSpace() }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
