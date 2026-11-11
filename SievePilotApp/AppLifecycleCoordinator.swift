import AppKit
import Foundation

@MainActor
final class AppLifecycleCoordinator {
    private weak var model: AppModel?
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel, notificationCenter: NotificationCenter = .default) {
        self.model = model
        observers.append(notificationCenter.addObserver(forName: NSApplication.didResignActiveNotification,
                                                        object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in model?.markStale() }
        })
        observers.append(notificationCenter.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                        object: nil, queue: .main) { [weak model] _ in
            Task { @MainActor in
                guard let model, model.persistedAccount != nil else { return }
                await model.refresh()
            }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
