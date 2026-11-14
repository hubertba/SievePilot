import SwiftUI

/// Edit or delete the single configured account. Test & Save re-verifies with the entered password.
struct AccountSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Account Settings").font(.headline)
                Spacer()
                Button("Done") { model.closeSettings() }
                    .disabled(model.isOperationInProgress)
            }
            StatusBanner(state: model.operationState, message: model.userFacingError)
            TextField("Email address", text: $model.emailAddress)
                .textFieldStyle(.roundedBorder)
            TextField("Username", text: $model.username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password (required to re-verify)", text: $model.password)
                .textFieldStyle(.roundedBorder)
            Toggle("Discover server automatically", isOn: $model.usesAutomaticDiscovery)
            if !model.usesAutomaticDiscovery {
                TextField("Server", text: $model.manualHost)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $model.manualPort)
                    .textFieldStyle(.roundedBorder)
            }
            if let preview = model.discoveryPreview {
                LabeledContent("Discovered server", value: preview)
            }
            HStack {
                Button("Test & Save") { Task { await model.testAndSave() } }
                    .buttonStyle(.borderedProminent)
                Button("Delete Account", role: .destructive) { confirmingDelete = true }
                if model.userFacingError != nil {
                    Button("Acknowledge") { model.acknowledgeError() }
                }
            }
            .disabled(model.isOperationInProgress)
        }
        .padding()
        .confirmationDialog("Delete this account and its saved password?", isPresented: $confirmingDelete) {
            Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scripts already on the server are not changed.")
        }
    }
}
