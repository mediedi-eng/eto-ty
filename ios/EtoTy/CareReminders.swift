import Foundation
import UserNotifications

enum CareReminderEvent {
    case opened
    case foreground
}

enum CareReminderStatus {
    case none, scheduled, quiet, denied, notRequested, unavailable, expired

    var text: String? {
        switch self {
        case .none: return nil
        case .scheduled: return "Напоминание запланировано на этом устройстве."
        case .quiet: return "Напоминание запланировано. Его показ ограничен настройками уведомлений."
        case .denied: return "Уведомления выключены. Вопрос будет ждать в диалоге. Разрешение можно изменить в настройках устройства."
        case .notRequested: return "Вопрос будет ждать в диалоге. Чтобы включить уведомление, подтверди время напоминания."
        case .unavailable: return "Не удалось запланировать уведомление. Договорённость сохранена в диалоге."
        case .expired: return "Согласованное время уже наступило. Открой диалог."
        }
    }
}

@MainActor
final class CareReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CareReminders()

    // A personal profile has exactly one next contact on this device.
    private nonisolated static let identifier = "eto-ty.personal.next-contact"
    private let center = UNUserNotificationCenter.current()
    private var revision = 0
    private var target: Date?
    private var mayAsk = false
    private var work: Task<CareReminderStatus, Never>?

    private var pendingEvents: [CareReminderEvent] = []
    var onEvent: ((CareReminderEvent) -> Void)? {
        didSet {
            guard let onEvent else { return }
            let events = pendingEvents
            pendingEvents.removeAll()
            for event in events { onEvent(event) }
        }
    }

    override init() {
        super.init()
        center.delegate = self
    }

    func reconcile(date: Date?, requestPermission: Bool = false) async -> CareReminderStatus {
        if target != date {
            mayAsk = false
            if target != nil { clearReminder() }
        }
        target = date
        mayAsk = date != nil && (mayAsk || requestPermission)
        revision += 1
        let current = revision
        if date == nil { clearReminder() }

        // UN's add() is asynchronous. Finish any older submission before writing the new date.
        let previous = work
        let task = Task { @MainActor () -> CareReminderStatus in
            if let previous { _ = await previous.value }
            guard current == self.revision else { return .none }
            guard let date else {
                self.clearReminder()
                return .none
            }
            return await self.install(date, revision: current)
        }
        work = task
        let result = await task.value
        if current == revision {
            work = nil
            mayAsk = false
        }
        return result
    }

    private func install(_ date: Date, revision current: Int) async -> CareReminderStatus {
        guard date > Date() else {
            clearReminder()
            return .expired
        }
        var settings = await center.notificationSettings()
        guard revision == current else { return .none }
        do {
            if settings.authorizationStatus == .notDetermined && mayAsk {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            guard revision == current else { return .none }
            let status: CareReminderStatus
            switch settings.authorizationStatus {
            case .denied:
                clearReminder()
                return .denied
            case .notDetermined:
                clearReminder()
                return .notRequested
            case .authorized:
                status = settings.alertSetting == .enabled && settings.lockScreenSetting == .enabled ? .scheduled : .quiet
            case .provisional:
                status = .quiet
            #if os(iOS)
            case .ephemeral:
                status = .quiet
            #endif
            @unknown default:
                clearReminder()
                return .unavailable
            }

            let pending = await center.pendingNotificationRequests()
            guard revision == current else { return .none }
            guard date > Date() else {
                clearReminder()
                return .expired
            }
            // Keep an already installed request, including across a cold start.
            let second = ceil(date.timeIntervalSince1970)
            if pending.contains(where: {
                $0.identifier == Self.identifier && ($0.content.userInfo["due"] as? NSNumber)?.doubleValue == second
            }) { return status }

            let content = UNMutableNotificationContent()
            content.title = "Это ты"
            content.body = "В диалоге тебя ждёт сообщение."
            content.sound = .default
            content.userInfo = ["due": second]
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let fields: Set<Calendar.Component> = [.timeZone, .year, .month, .day, .hour, .minute, .second]
            let components = calendar.dateComponents(fields, from: Date(timeIntervalSince1970: second))
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
            try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger))
            guard revision == current else { return .none }
            return status
        } catch {
            clearReminder()
            return .unavailable
        }
    }

    private func clearReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    private func deliver(_ event: CareReminderEvent) {
        if let onEvent { onEvent(event) } else { pendingEvents.append(event) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard notification.request.identifier == Self.identifier else { return [] }
        await deliver(.foreground)
        return []
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.identifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await deliver(.opened)
    }
}

#if os(iOS)
import UIKit

@MainActor
final class CareNotificationBootstrap: NSObject, UIApplicationDelegate {
    static let externalDocumentDidOpen = Notification.Name("CareExternalDocumentDidOpen")
    private static var pendingExternalDocuments = [URL]()

    func application(_ application: UIApplication,
                     willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = CareReminders.shared
        return true
    }

    func application(_ application: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard url.isFileURL else { return false }
        Self.pendingExternalDocuments.append(url)
        NotificationCenter.default.post(name: Self.externalDocumentDidOpen, object: nil)
        return true
    }

    static func takeExternalDocuments() -> [URL] {
        defer { pendingExternalDocuments.removeAll() }
        return pendingExternalDocuments
    }
}
#endif
