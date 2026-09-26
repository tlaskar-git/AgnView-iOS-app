import SwiftUI

/// A machine the details screen opens by id, so it follows renames.
struct OpenedMachine: Hashable {
    let id: String
}

/// One paired machine as a list row: its name and state on the left, then
/// either a small bordered Switch button or the Active label in the same
/// width slot, then a chevron that opens the details. Each control is its
/// own button, so the row works with VoiceOver and inside a List.
struct MachineRow: View {
    let hub: HubRecord
    let isActive: Bool
    let routeLabel: String
    let onOpen: () -> Void
    let onSwitch: () -> Void

    /// The Switch and Active slot: 72 pt wide, the visible button 32 pt high.
    static let slotWidth: CGFloat = 72
    static let buttonHeight: CGFloat = 32

    private var subtitle: String { isActive ? routeLabel : "Paired" }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hub.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(hub.name + ", " + subtitle)
            .accessibilityHint("Opens the machine details")
            .accessibilityIdentifier("machine-open")

            if isActive {
                Text("Active")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.success)
                    .frame(minWidth: Self.slotWidth, minHeight: Self.buttonHeight)
                    .accessibilityLabel("Active machine")
                    .accessibilityIdentifier("machine-active")
            } else {
                Button(action: onSwitch) {
                    Text("Switch")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.link)
                        .frame(minWidth: Self.slotWidth, minHeight: Self.buttonHeight)
                        .overlay(Capsule().strokeBorder(Theme.link, lineWidth: 1.5))
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Switch to " + hub.name)
                .accessibilityIdentifier("machine-switch-button")
            }

            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: Theme.minTap, height: Theme.minTap)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Details for " + hub.name)
            .accessibilityIdentifier("machine-info")
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 4))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("machine-row")
    }
}

/// One machine: rename it, see its connection, switch to it or remove it from
/// this phone.
struct MachineDetailView: View {
    let hubId: String

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: NavState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoval = false
    @State private var name = ""
    @State private var loaded = false

    private var hub: HubRecord? { model.hubs.first { $0.id == hubId } }
    private var isActive: Bool { hubId == model.activeHub?.id }

    var body: some View {
        Form {
            if let hub {
                Section {
                    TextField("Machine name", text: $name)
                        .submitLabel(.done)
                        .onSubmit { save(hub) }
                        .frame(minHeight: Theme.minTap)
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("machine-name")
                    if canSave(hub) {
                        Button("Save name") { save(hub) }
                            .frame(minHeight: Theme.minTap, alignment: .leading)
                            .accessibilityIdentifier("machine-save")
                    }
                } header: {
                    Text("Name")
                }
                Section("Connection") {
                    LabeledContent("Status", value: isActive ? "Active, " + model.route.label : "Paired")
                    if isActive {
                        Text(model.statusLine)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Section {
                    if !isActive {
                        Button {
                            model.switchTo(hub.id)
                            nav.showToast("Switched to " + hub.name)
                        } label: {
                            Text("Switch to this machine")
                                .frame(minHeight: Theme.minTap, alignment: .leading)
                        }
                        .accessibilityIdentifier("machine-switch")
                    }
                    Button(role: .destructive) {
                        confirmRemoval = true
                    } label: {
                        Text("Remove from this phone")
                            .frame(minHeight: Theme.minTap, alignment: .leading)
                    }
                    .accessibilityIdentifier("machine-remove")
                }
            }
        }
        .navigationTitle(hub?.name ?? "Machine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            if !loaded, let hub {
                name = hub.name
                loaded = true
            }
        }
        .confirmationDialog("Remove this machine?", isPresented: $confirmRemoval,
                            titleVisibility: .visible) {
            Button("Remove from this phone", role: .destructive) {
                model.remove(hubId)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(UserMessages.removedFromPhone)
        }
        .accessibilityIdentifier("machine-detail")
    }

    private func canSave(_ hub: HubRecord) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != hub.name
    }

    private func save(_ hub: HubRecord) {
        guard canSave(hub) else { return }
        model.rename(hub.id, to: name)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        nav.showToast("Saved")
    }
}
