import AppKit
import SievePilotCore
import SwiftUI

@main
struct SievePilotApp: App {
    @StateObject private var model: AppModel
    private let lifecycle: AppLifecycleCoordinator

    @MainActor
    init() {
        let model = AppModel(dependencies: .production())
        _model = StateObject(wrappedValue: model)
        lifecycle = AppLifecycleCoordinator(model: model)
    }

    var body: some Scene {
        MenuBarExtra(AppModel.productName, systemImage: "line.3.horizontal.decrease.circle") {
            SetupView(model: model)
                .task { await model.load() }
            Divider()
            Button("Quit SievePilot") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.window)
    }
}
