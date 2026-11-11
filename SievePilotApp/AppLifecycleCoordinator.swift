import AppKit
import Foundation
import Network

enum AppLifecycleEvent: Sendable, Equatable {
    case didResignActive
    case didBecomeActive
    case didWake
    case networkLost
    case networkReconnected
}

/// Boundary between the model and the platform lifecycle so tests can drive events without `NSApplication`.
@MainActor
protocol AppLifecycleObserving: AnyObject {
    func start(_ handler: @escaping @MainActor @Sendable (AppLifecycleEvent) -> Void)
}

/// A reduced view of the system network path. `signature` changes when the usable interfaces change.
struct NetworkPathStatus: Equatable, Sendable {
    let isSatisfied: Bool
    let signature: String
}

/// Boundary around the system network-path monitor; tests inject a fake and production wraps `NWPathMonitor`.
@MainActor
protocol NetworkPathMonitoring: AnyObject {
    func start(_ handler: @escaping @MainActor @Sendable (NetworkPathStatus) -> Void)
    func stop()
}

@MainActor
final class SystemNetworkPathMonitor: NetworkPathMonitoring {
    private var monitor: NWPathMonitor?

    func start(_ handler: @escaping @MainActor @Sendable (NetworkPathStatus) -> Void) {
        stop()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let signature = path.availableInterfaces.map { "\($0.type):\($0.name)" }.joined(separator: ",")
            let status = NetworkPathStatus(isSatisfied: path.status == .satisfied, signature: signature)
            Task { @MainActor in handler(status) }
        }
        monitor.start(queue: DispatchQueue(label: "com.hubertba.SievePilot.network-path"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    deinit { monitor?.cancel() }
}

@MainActor
final class AppLifecycleCoordinator: AppLifecycleObserving {
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let pathMonitor: any NetworkPathMonitoring
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var lastPath: NetworkPathStatus?

    init(notificationCenter: NotificationCenter = .default,
         workspaceNotificationCenter: NotificationCenter? = nil,
         pathMonitor: (any NetworkPathMonitoring)? = nil) {
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter ?? NSWorkspace.shared.notificationCenter
        self.pathMonitor = pathMonitor ?? SystemNetworkPathMonitor()
    }

    func start(_ handler: @escaping @MainActor @Sendable (AppLifecycleEvent) -> Void) {
        stop()
        let pairs: [(NotificationCenter, Notification.Name, AppLifecycleEvent)] = [
            (notificationCenter, NSApplication.didResignActiveNotification, .didResignActive),
            (notificationCenter, NSApplication.didBecomeActiveNotification, .didBecomeActive),
            (workspaceNotificationCenter, NSWorkspace.didWakeNotification, .didWake)
        ]
        for (center, name, event) in pairs {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in handler(event) }
            }
            observers.append((center, token))
        }
        pathMonitor.start { [weak self] status in
            guard let self else { return }
            if let event = self.transition(to: status) { handler(event) }
        }
    }

    /// The first update is only a baseline. Later updates map to loss, or to reconnection when connectivity
    /// returns or the set of usable interfaces changes.
    private func transition(to status: NetworkPathStatus) -> AppLifecycleEvent? {
        defer { lastPath = status }
        guard let previous = lastPath else { return nil }
        if !status.isSatisfied { return previous.isSatisfied ? .networkLost : nil }
        if !previous.isSatisfied || previous.signature != status.signature { return .networkReconnected }
        return nil
    }

    private func stop() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
        pathMonitor.stop()
        lastPath = nil
    }

    deinit {
        for observer in observers { observer.center.removeObserver(observer.token) }
    }
}
