import SievePilotCore
import SwiftUI

/// Compact operational popover. It renders model state only and never infers success from a request.
struct OutOfOfficeView: View {
    private struct ScriptDeletionConfirmation: Identifiable {
        let name: String
        let wasActive: Bool
        var id: String { name }
    }

    @ObservedObject var model: AppModel
    @State private var pendingScriptDeletion: ScriptDeletionConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusRow
            scriptList
            selectedScriptDetail
            if let error = model.userFacingError { errorBanner(error) }
            if !model.capabilityLimitations.isEmpty { limitations }
            form
            actions
            footer
        }
        .padding()
        .task { await model.popoverDidOpen() }
        .alert(item: $pendingScriptDeletion) { deletion in
            Alert(
                title: Text("Delete “\(deletion.name)”?"),
                message: Text(deletion.wasActive
                    ? "This script is active. SievePilot will deactivate it first, leaving no active Sieve script or mail rules, and then permanently delete it."
                    : "This will permanently delete the script from the server. This action cannot be undone."),
                primaryButton: .destructive(Text(deletion.wasActive ? "Deactivate and Delete" : "Delete Script")) {
                    Task { await model.deleteScript(named: deletion.name) }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppModel.productName).font(.headline)
            HStack {
                Text("Account: \(model.persistedAccount?.emailAddress ?? "")").lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Settings") { model.showSettings() }
            }
            HStack {
                Text("Server: \(model.serverDescription)").lineLimit(1).truncationMode(.middle)
                Spacer()
                if let verifiedAt = model.verifiedAt {
                    Text("Verified \(verifiedAt.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                } else {
                    Text(model.isOperationInProgress ? "Verifying…" : "Not verified").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    private var statusRow: some View {
        let status = model.outOfOfficeStatus
        return HStack(alignment: .firstTextBaseline) {
            Text("Out of Office").font(.headline)
            Spacer()
            Label(status.label, systemImage: symbol(for: status))
                .foregroundStyle(color(for: status))
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Acknowledge") { model.acknowledgeError() }
        }
        .font(.callout)
    }

    private var scriptList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scripts on server").font(.headline)
            if model.listedScripts.isEmpty {
                Text(model.verifiedSnapshot == nil
                     ? "Refresh to load scripts from the server."
                     : "No scripts on this server.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.listedScripts, id: \.name) { script in
                            scriptRow(script)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private func scriptRow(_ script: ManageSieveScriptEntry) -> some View {
        let isSelected = script.name == model.selectedScriptName
        return Button {
            Task { await model.selectScript(script.name) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: script.isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(script.isActive ? Color.green : Color.secondary)
                Text(script.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Spacer()
                if script.isActive {
                    Text("Active").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var selectedScriptDetail: some View {
        if model.selectedScriptName != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Selected script").font(.headline)
                selectedScriptConfiguration
                selectedScriptContent
                HStack {
                    Spacer()
                    Button("Delete Script", role: .destructive) {
                        guard let script = model.selectedScriptEntry else { return }
                        pendingScriptDeletion = ScriptDeletionConfirmation(name: script.name,
                                                                           wasActive: script.isActive)
                    }
                    .disabled(!model.canDeleteSelectedScript)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedScriptConfiguration: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Configuration").font(.callout).foregroundStyle(.secondary)
            if let entry = model.selectedScriptEntry {
                labeled("Name", entry.name)
                labeled("Status", entry.isActive ? "Active" : "Inactive")
            }
            if model.isLoadingSelectedScript {
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            } else if model.scriptInspectError != nil {
                Text("Unable to load this script.").font(.callout).foregroundStyle(.red)
            } else {
                switch model.selectedScriptOutOfOfficeState {
                case .on(let configuration):
                    managedConfiguration(configuration, expired: false)
                case .expiryPassedServerClockApplies(let configuration):
                    managedConfiguration(configuration, expired: true)
                case .malformed:
                    Text("This script has SievePilot markers that could not be parsed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .off:
                    Text("No SievePilot out-of-office configuration in this script.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .none:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private func managedConfiguration(_ configuration: ParsedOutOfOfficeConfiguration, expired: Bool) -> some View {
        labeled("Vacation", expired ? "Expiry passed — server clock applies" : "SievePilot out of office")
        labeled("Address", configuration.emailAddress)
        if let subject = configuration.subject, !subject.isEmpty {
            labeled("Subject", subject)
        }
        labeled("Message", configuration.message)
        labeled("Expiry", configuration.expiryInstant.formatted(date: .abbreviated, time: .shortened))
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var selectedScriptContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Content").font(.callout).foregroundStyle(.secondary)
            if model.isLoadingSelectedScript {
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            } else if model.scriptInspectError != nil {
                EmptyView()
            } else if model.selectedScriptBytes == nil {
                Text("No script body.").font(.callout).foregroundStyle(.secondary)
            } else if let source = model.selectedScriptSource {
                ScrollView {
                    Text(displayedSource(source))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            } else {
                Text("This script is not valid UTF-8 text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func displayedSource(_ source: String) -> String {
        let limit = 12_000
        guard source.count > limit else { return source }
        return String(source.prefix(limit)) + "\n… (truncated)"
    }

    private var limitations: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.capabilityLimitations, id: \.self) { text in
                Label(text, systemImage: "info.circle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var form: some View {
        if model.isOutOfOfficeAvailable {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Subject (optional)", text: $model.subject)
                Text("Message").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $model.message)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                expiryControls
                ruleOrderNotice
            }
            .disabled(model.isOperationInProgress)
        }
    }

    private var expiryControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Turn off").font(.callout).foregroundStyle(.secondary)
            HStack {
                DatePicker("Date", selection: pickerBinding, displayedComponents: .date)
                DatePicker("Time", selection: pickerBinding, displayedComponents: .hourAndMinute)
            }
            .labelsHidden()
            .environment(\.timeZone, model.expiryTimeZone)
            Picker("Time zone", selection: $model.expiryTimeZoneIdentifier) {
                ForEach(AppModel.availableTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
            }
            expiryDiagnostics
        }
    }

    @ViewBuilder
    private var expiryDiagnostics: some View {
        switch model.expiryStatus {
        case .nonexistentLocalTime:
            Label("That local time does not exist (daylight-saving change). Choose another time.",
                  systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
        case .repeatedLocalTimeNeedsConfirmation(let offsets):
            offsetPicker(offsets, prompt: "That local time occurs twice. Confirm the UTC offset:")
        case .valid where !model.repeatedTimeOffsetOptions.isEmpty:
            offsetPicker(model.repeatedTimeOffsetOptions, prompt: "That local time occurs twice. Confirmed UTC offset:")
        case .inPast:
            Label("Choose a time in the future.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red).font(.callout)
        case .invalidLocalTime:
            Label("Choose a valid date, time, and time zone.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red).font(.callout)
        case .valid:
            EmptyView()
        }
    }

    private func offsetPicker(_ offsets: [Int], prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(prompt).font(.callout).foregroundStyle(.orange)
            Picker("UTC offset", selection: $model.repeatedTimeOffset) {
                Text("Choose…").tag(Int?.none)
                ForEach(offsets, id: \.self) { Text(AppModel.utcOffsetLabel($0)).tag(Int?.some($0)) }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var ruleOrderNotice: some View {
        if !model.ruleOrderingAcknowledged {
            VStack(alignment: .leading, spacing: 4) {
                Text("The vacation action runs before your existing executable rules, so a later `stop` cannot disable it. Custom spam, discard, redirect, or other guard rules may no longer suppress the vacation response.")
                    .font(.callout)
                Button("I Understand") { model.acknowledgeRuleOrdering() }
            }
            .padding(8)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var actions: some View {
        HStack {
            Button("Refresh") { Task { await model.requestRefresh() } }
                .disabled(model.isOperationInProgress)
            if model.outOfOfficeStatus != .verifiedOff {
                Button("Disable") { Task { await model.disable() } }
                    .disabled(!model.canDisable)
            }
            Spacer()
            if model.isOutOfOfficeAvailable {
                Button("Save and Activate") { Task { await model.saveAndActivate() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSaveAndActivate)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let verifiedAt = model.verifiedAt {
            Text("Last server update: \(verifiedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Server state is not verified; refresh to confirm it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pickerBinding: Binding<Date> {
        Binding(get: { model.expiryPickerDate }, set: { model.setExpiry(fromPickerDate: $0) })
    }

    private func symbol(for status: AppModel.OutOfOfficeStatus) -> String {
        switch status {
        case .verifiedOn: "checkmark.circle.fill"
        case .verifiedOff: "moon.zzz"
        case .expiryPassed: "clock.badge.checkmark"
        case .unknown: "questionmark.circle"
        case .conflict: "exclamationmark.triangle.fill"
        }
    }

    private func color(for status: AppModel.OutOfOfficeStatus) -> Color {
        switch status {
        case .verifiedOn: .green
        case .verifiedOff, .expiryPassed: .secondary
        case .unknown: .orange
        case .conflict: .red
        }
    }
}
