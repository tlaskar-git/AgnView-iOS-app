import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: NavState
    @AppStorage(AppearanceChoice.storageKey) private var appearance = AppearanceChoice.system.rawValue
    @State private var pendingRemoval: HubRecord?

    private var showDialog: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    var body: some View {
        ScreenChrome(screen: .settings) {
            VStack(alignment: .leading, spacing: 20) {
                machinesSection
                connectionSection
                appearanceSection
                aboutSection
                unpairSection
            }
            .padding(.bottom, 24)
        }
        .confirmationDialog("Remove this machine?",
                            isPresented: showDialog,
                            titleVisibility: .visible,
                            presenting: pendingRemoval) { hub in
            Button("Remove from this phone", role: .destructive) {
                model.remove(hub.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(UserMessages.removedFromPhone)
        }
    }

    // MARK: Sections

    private var machinesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Paired machines")
            if model.hubs.isEmpty {
                Text("No machine paired yet.")
                    .foregroundStyle(Theme.textSecondary)
                    .card()
                    .accessibilityIdentifier("machines-empty")
            }
            ForEach(model.hubs) { hub in
                MachineRow(hub: hub,
                           isActive: hub.id == model.activeHub?.id,
                           routeLabel: model.route.label,
                           onSwitch: { model.switchTo(hub.id) },
                           onRemove: { pendingRemoval = hub })
            }
            Button {
                nav.showPairing = true
            } label: {
                Label("Add machine", systemImage: "plus")
                    .frame(maxWidth: .infinity, minHeight: Theme.minTap)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("add-machine")
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Connection")
            VStack(alignment: .leading, spacing: 6) {
                Text(model.route.label)
                    .font(.headline)
                    .foregroundStyle(Theme.textMain)
                Text(model.statusLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                if let message = model.statusMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Theme.warning)
                }
            }
            .card()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("connection-status")
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Appearance")
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Text(choice.title).tag(choice.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: Theme.minTap)
            .accessibilityIdentifier("appearance-picker")
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("About")
            HStack {
                Text("Version")
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(versionText)
                    .foregroundStyle(Theme.textMain)
            }
            .card()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("app-version")
        }
    }

    private var unpairSection: some View {
        Button(role: .destructive) {
            pendingRemoval = model.activeHub
        } label: {
            Text("Unpair current machine")
                .frame(maxWidth: .infinity, minHeight: Theme.minTap)
        }
        .buttonStyle(.bordered)
        .disabled(model.activeHub == nil)
        .accessibilityIdentifier("unpair-current")
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        if let build = info?["CFBundleVersion"] as? String {
            return short + " (" + build + ")"
        }
        return short
    }
}

private struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(Theme.textMain)
            .accessibilityAddTraits(.isHeader)
    }
}

struct MachineRow: View {
    let hub: HubRecord
    let isActive: Bool
    let routeLabel: String
    let onSwitch: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(hub.name)
                        .font(.headline)
                        .foregroundStyle(Theme.textMain)
                    if isActive {
                        Text("Active, " + routeLabel)
                            .font(.footnote)
                            .foregroundStyle(Theme.success)
                    }
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                if !isActive {
                    Button("Switch", action: onSwitch)
                        .buttonStyle(.bordered)
                        .frame(minHeight: Theme.minTap)
                        .accessibilityIdentifier("machine-switch")
                }
                Button("Remove from this phone", role: .destructive, action: onRemove)
                    .buttonStyle(.bordered)
                    .frame(minHeight: Theme.minTap)
                    .accessibilityIdentifier("machine-remove")
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("machine-row")
    }
}
