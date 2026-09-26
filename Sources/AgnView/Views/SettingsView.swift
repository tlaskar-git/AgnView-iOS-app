import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var nav: NavState
    @AppStorage(AppearanceChoice.storageKey) private var appearance = AppearanceChoice.system.rawValue
    @State private var pendingRemoval: HubRecord?
    @State private var opened: OpenedMachine?

    private var showDialog: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private let about = AboutInfo()

    var body: some View {
        ScreenChrome(screen: .settings) {
            Form {
                BannerSection()
                machinesSection
                connectionSection
                appearanceSection
                aboutSection
                unpairSection
            }
            .navigationDestination(item: $opened) { machine in
                MachineDetailView(hubId: machine.id)
            }
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
        Section {
            if model.hubs.isEmpty {
                Text("No machine paired yet.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("machines-empty")
            }
            ForEach(model.hubs) { hub in
                MachineRow(hub: hub,
                           isActive: hub.id == model.activeHub?.id,
                           routeLabel: model.route.label,
                           onOpen: { opened = OpenedMachine(id: hub.id) },
                           onSwitch: { switchTo(hub) })
            }
            Button {
                nav.showPairing = true
            } label: {
                Label("Add machine", systemImage: "plus")
                    .frame(minHeight: Theme.minTap, alignment: .leading)
            }
            .accessibilityIdentifier("add-machine")
        } header: {
            Text("Paired machines")
        } footer: {
            if !model.hubs.isEmpty {
                Text("Tap Switch to change the active machine. Tap a row for details.")
            }
        }
    }

    /// Switches at once, with a haptic and a toast. The route pill follows the
    /// new machine as soon as the connection settles.
    private func switchTo(_ hub: HubRecord) {
        model.switchTo(hub.id)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        nav.showToast("Switched to " + hub.name)
    }

    private var connectionSection: some View {
        Section("Connection") {
            NavigationLink {
                ConnectionDetailView()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.route.label)
                        .foregroundStyle(.primary)
                    Text(model.statusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: Theme.minTap, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            .accessibilityIdentifier("connection-status")
        }
    }

    /// The appearance choice sits in its own section as a segmented control.
    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { choice in
                    Text(choice.title).tag(choice.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: Theme.minTap)
            .accessibilityIdentifier("appearance-picker")
        } header: {
            Text("Appearance")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: about.version)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(about.versionLabel)
                .accessibilityIdentifier("app-version")
            LabeledContent("Build", value: about.build)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Build " + about.build)
                .accessibilityIdentifier("app-build")
        }
    }

    private var unpairSection: some View {
        Section {
            Button(role: .destructive) {
                pendingRemoval = model.activeHub
            } label: {
                Text("Unpair current machine")
                    .frame(maxWidth: .infinity, minHeight: Theme.minTap)
            }
            .disabled(model.activeHub == nil)
            .accessibilityIdentifier("unpair-current")
        }
    }
}

/// What the About section shows. The marketing version and the build number
/// are separate values and are never joined into one string.
struct AboutInfo: Equatable {
    let version: String
    let build: String

    init(info: [String: Any]? = Bundle.main.infoDictionary) {
        version = AppVersion.marketing(from: info) ?? "Unknown"
        build = AppVersion.build(from: info) ?? "Unknown"
    }

    /// The spoken and tested form, such as "Version 1.0.3".
    var versionLabel: String { "Version " + version }
}

/// Reads the version numbers for Settings.
enum AppVersion {
    /// CFBundleShortVersionString, trimmed. Nil when it is missing or empty.
    static func marketing(from info: [String: Any]?) -> String? {
        clean(info?["CFBundleShortVersionString"])
    }

    /// CFBundleVersion, trimmed. Nil when it is missing or empty.
    static func build(from info: [String: Any]?) -> String? {
        clean(info?["CFBundleVersion"])
    }

    /// The marketing version only, such as "Version 1.0.3". The build number
    /// is never part of this line.
    static func text(from info: [String: Any]?) -> String {
        guard let short = marketing(from: info) else { return "Unknown" }
        return "Version " + short
    }

    private static func clean(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }
}

/// How the app reaches the computer right now, and why.
struct ConnectionDetailView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Route", value: model.route.label)
                if let hub = model.activeHub {
                    LabeledContent("Machine", value: hub.name)
                }
            }
            Section("Status") {
                Text(model.statusLine)
                if let message = model.statusMessage {
                    Text(message)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .navigationTitle("Connection")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("connection-detail")
    }
}
