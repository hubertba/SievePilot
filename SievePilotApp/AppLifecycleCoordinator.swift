import AppKit
import Foundation

enum AppLifecycleEvent: Sendable, Equatable {
    case didResignActive
    case didBecomeActive
}

/// Boundary between the model and the platform lifecycle so tests can drive events without `NSApplication`.
@MainActor
protocol AppLifecycleObserving: AnyObject {
    func start(_ handler: @escaping @MainActor @Sendable (AppLifecycleEvent) -> Void)
}

@MainActor
final class AppLifecycleCoordinator: AppLifecycleObserving {
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func start(_ handler: @escaping @MainActor @Sendable (AppLifecycleEvent) -> Void) {
        stop()
        let pairs: [(Notification.Name, AppLifecycleEvent)] = [
            (NSApplication.didResignActiveNotification, .didResignActive),
            (NSApplication.didBecomeActiveNotification, .didBecomeActive)
        ]
        for (name, event) in pairs {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in handler(event) }
            })
        }
    }

    private func stop() {
        for observer in observers { notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    deinit {
        for observer in observers { notificationCenter.removeObserver(observer) }
    }
}
