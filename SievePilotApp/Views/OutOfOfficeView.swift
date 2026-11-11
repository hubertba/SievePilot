import SwiftUI

/// Compact operational popover. It renders model state only and never infers success from a request.
struct OutOfOfficeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            statusRow
            if let error = model.userFacingError { errorBanner(error) }
            if !model.capabilityLimitations.isEmpty { limitations }
            form
            actions
            footer
        }
        .padding()
        .frame(width: 390)
        .task { await model.popoverDidOpen() }
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
