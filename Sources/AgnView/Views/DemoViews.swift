import SwiftUI

/// The strip every screen shows while the demo runs.
struct DemoBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "play.rectangle")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(UserMessages.demoBanner)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Rectangle().fill(.bar)
                Rectangle().fill(Theme.warning.opacity(0.15))
            }
        }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("demo-banner")
    }
}

/// The two actions under the onboarding buttons: the demo and the link to the
/// desktop app.
struct OnboardingLinks: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 8) {
            Button("Try the demo") { model.startDemo() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("state-onboarding-demo")
            Button("Get AgnView for your computer") { openURL(AppLinks.getDesktop) }
                .frame(minHeight: Theme.minTap)
                .accessibilityIdentifier("state-onboarding-get-desktop")
        }
    }
}

/// A Settings row that opens a web address outside the app.
struct LinkRow: View {
    let title: String
    let url: URL
    let identifier: String

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.minTap)
        }
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier(identifier)
    }
}

/// The open source components inside the app and their licences.
struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                Text("AgnView contains the open source components below. Each one keeps its own licence.")
                    .captionRow()
            }
            ForEach(Acknowledgement.all) { item in
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Licence")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.licence)
                    }
                    .accessibilityElement(children: .combine)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copyright")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.holder)
                    }
                    .accessibilityElement(children: .combine)
                    LinkRow(title: "Source code", url: item.source,
                            identifier: "ack-source-" + item.source.lastPathComponent)
                } header: {
                    Text(item.name).textCase(nil)
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("acknowledgements")
    }
}
