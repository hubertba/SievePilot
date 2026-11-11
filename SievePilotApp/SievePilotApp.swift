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
        // Load and verify exactly once at launch; opening the popover requests its own coalesced refresh.
        Task { @MainActor in await model.loadAndRefresh() }
    }

    var body: some Scene {
        MenuBarExtra(AppModel.productName, systemImage: "line.3.horizontal.decrease.circle") {
            PopoverContent(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Chooses the first-run setup, the operational out-of-office menu, or account settings from model state only.
struct PopoverContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.persistedAccount == nil {
                SetupView(model: model)
            } else if model.isShowingSettings {
                AccountSettingsView(model: model)
            } else {
                OutOfOfficeView(model: model)
            }
            Divider()
            HStack {
                Spacer()
                Button("Quit SievePilot") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }
}
