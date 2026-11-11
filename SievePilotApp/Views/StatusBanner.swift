import SwiftUI

struct StatusBanner: View {
    let state: AppModel.OperationState
    let message: String?

    var body: some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else {
            Label(title, systemImage: symbol)
                .foregroundStyle(color)
        }
    }

    private var title: String {
        switch state {
        case .idle: "Not configured"
        case .loading: "Loading…"
        case .testing: "Testing secure connection…"
        case .refreshing: "Refreshing…"
        case .applying: "Applying out-of-office change…"
        case .stale: "Refresh to verify server state"
        case .verified: "Server state verified"
        case .unknown: "Server state unknown"
        case .error: "Action required"
        }
    }

    private var symbol: String {
        switch state {
        case .verified: "checkmark.circle.fill"
        case .unknown, .stale: "questionmark.circle"
        case .error: "exclamationmark.triangle.fill"
        default: "circle"
        }
    }

    private var color: Color {
        switch state {
        case .verified: .green
        case .unknown, .stale: .orange
        case .error: .red
        default: .secondary
        }
    }
}
