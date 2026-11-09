import AppKit
import SievePilotCore
import SwiftUI

@main
struct SievePilotApp: App {
    var body: some Scene {
        MenuBarExtra(
            AppModel.productName,
            systemImage: "line.3.horizontal.decrease.circle"
        ) {
            Text(AppModel.productName)
                .font(.headline)
            Text(AppModel.coreStatus)
            Divider()
            Button("Quit SievePilot") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
