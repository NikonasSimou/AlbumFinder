import BackgroundTasks
import Foundation
import UserNotifications

/// Keeps a run going when the user leaves the app (iOS shows its progress meanwhile), and posts a
/// notification when it ends. If iOS declines, the run simply continues in the foreground.
final class BackgroundRun {
    static let units: Int64 = 1000

    private var task: BGContinuedProcessingTask?

    /// `onExpire` is called if iOS has to stop the run early, e.g. on low battery.
    init(onExpire: @escaping @MainActor () -> Void) {
        let identifier = "\(Bundle.main.bundleIdentifier!).analyze.\(UUID().uuidString)"
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else { return }
                task.progress.totalUnitCount = Self.units
                task.expirationHandler = { Task { @MainActor in onExpire() } }
                self?.task = task
            }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Finding albums", subtitle: "Starting…")
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    /// `done` is how much of the whole run is finished, from 0 to 1. iOS stops runs whose progress
    /// stops moving, so this should be called often.
    func update(_ description: String, done: Double) {
        task?.progress.completedUnitCount = Int64(done * Double(Self.units))
        task?.updateTitle("Finding albums", subtitle: description)
    }

    func finish(title: String, message: String, success: Bool) {
        task?.progress.completedUnitCount = Self.units
        task?.setTaskCompleted(success: success)
        // Shown only while the app is in the background: in the foreground the result is already on screen.
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
}
