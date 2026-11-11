import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            StatusBanner(state: model.operationState, message: model.userFacingError)
            TextField("Email address", text: $model.emailAddress)
            TextField("Username", text: $model.username)
            SecureField("Password", text: $model.password)
            Toggle("Discover server automatically", isOn: $model.usesAutomaticDiscovery)
            if !model.usesAutomaticDiscovery {
                TextField("Server", text: $model.manualHost)
                TextField("Port", text: $model.manualPort)
            }
            if let preview = model.discoveryPreview {
                LabeledContent("Discovered server", value: preview)
            }
            HStack {
                Button("Test & Save") { Task { await model.testAndSave() } }
                    .buttonStyle(.borderedProminent)
                if model.persistedAccount != nil {
                    Button("Refresh") { Task { await model.refresh() } }
                    Button("Delete Account", role: .destructive) { Task { await model.deleteAccount() } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 390)
        .padding()
    }
}
