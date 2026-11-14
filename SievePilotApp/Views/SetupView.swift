import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppModel.productName).font(.headline)
            StatusBanner(state: model.operationState, message: model.userFacingError)
            TextField("Email address", text: $model.emailAddress)
                .textFieldStyle(.roundedBorder)
            TextField("Username", text: $model.username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $model.password)
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
                    .disabled(model.isOperationInProgress)
            }
        }
        .padding()
        .disabled(model.isOperationInProgress && model.operationState == .testing)
    }
}
