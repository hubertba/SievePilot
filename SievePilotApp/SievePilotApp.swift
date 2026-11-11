import AppKit
import SievePilotCore
import SwiftUI

@main
struct SievePilotApp: App {
    @StateObject private var model: AppModel

    @MainActor
    init() {
        let model = AppModel(dependencies: .production())
        _model = StateObject(wrappedValue: model)
        // Load exactly once at launch; `.task` on the popover content re-runs on every open.
        Task { @MainActor in await model.load() }
    }

    var body: some Scene {
        MenuBarExtra(AppModel.productName, systemImage: "line.3.horizontal.decrease.circle") {
            SetupView(model: model)
            Divider()
            Button("Quit SievePilot") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.window)
    }
}
