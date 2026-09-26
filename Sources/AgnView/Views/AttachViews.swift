import SwiftUI

/// The attached items as removable chips.
struct AttachmentChips: View {
    @Binding var items: [AttachmentItem]
    let identifierPrefix: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isHubFile ? "doc.text" : "paperclip")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                        Text(item.displayName)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                        Button {
                            items.removeAll { $0.id == item.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .imageScale(.small)
                                .frame(minWidth: 28, minHeight: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(item.displayName)")
                        .accessibilityIdentifier(identifierPrefix + "-attachment-remove")
                    }
                    .foregroundStyle(Theme.textMain)
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(Theme.raised))
                    .accessibilityIdentifier(identifierPrefix + "-attachment")
                }
            }
        }
    }
}

/// The attach sheet. Phase A lists files on the computer. The phone entries
/// are drawn but stay disabled until the hub can accept uploads.
struct AttachSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var attachments: [AttachmentItem]

    @State private var files: [String] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var filter = ""
    @State private var picked: Set<String> = []

    private var visible: [String] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? files : files.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("From your phone") {
                    phoneRow(title: "From Files, iCloud or OneDrive", symbol: "folder",
                             identifier: "attach-source-files")
                    phoneRow(title: "From Photos", symbol: "photo", identifier: "attach-source-photos")
                }
                Section("From this computer") {
                    computerRows
                }
            }
            .searchable(text: $filter, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Filter files")
            .navigationTitle("Attach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("attach-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.isEmpty ? "Done" : "Attach \(picked.count)") { apply() }
                        .accessibilityIdentifier("attach-confirm")
                }
            }
        }
        .presentationDetents([.large])
        .task {
            picked = Set(Attachments.hubPaths(attachments))
            await load()
        }
        .accessibilityIdentifier("attach-sheet")
    }

    /// A phone-side source. Disabled until `supportsPhoneUploads` turns on
    /// (phase B), with the reason under it.
    private func phoneRow(title: String, symbol: String, identifier: String) -> some View {
        let enabled = model.features.supportsPhoneUploads
        return Button {
            // Phase B opens the system picker here and adds a .localFile item.
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(enabled ? Theme.textMain : Theme.textSecondary)
                    if !enabled {
                        Text(HubFeatures.uploadsNeedsUpdateText)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(minHeight: Theme.minTap, alignment: .leading)
        }
        .disabled(!enabled)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var computerRows: some View {
        if !model.canAttachFromComputer {
            Text(UserMessages.computerFilesNeedSameWiFi)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("attach-unavailable")
        } else if loading {
            HStack(spacing: 8) {
                ProgressView()
                Text("Reading the files on your computer")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityIdentifier("attach-loading")
        } else if let failure {
            VStack(alignment: .leading, spacing: 8) {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(Theme.error)
                Button("Retry") { Task { await load() } }
                    .accessibilityIdentifier("attach-retry")
            }
        } else if visible.isEmpty {
            Text(files.isEmpty ? "The hub lists no files." : "No file matches.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("attach-empty")
        } else {
            ForEach(visible, id: \.self) { path in
                let chosen = picked.contains(path)
                Button {
                    if chosen { picked.remove(path) } else { picked.insert(path) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chosen ? Theme.action : Theme.textSecondary)
                            .accessibilityHidden(true)
                        Text(path)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(Theme.textMain)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(minHeight: Theme.minTap, alignment: .leading)
                }
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("attach-file-row")
            }
        }
    }

    private func load() async {
        guard model.canAttachFromComputer else {
            loading = false
            return
        }
        loading = true
        failure = nil
        do {
            files = try await model.hubFiles()
        } catch {
            failure = "The files could not be read. Try again."
        }
        loading = false
    }

    /// Keeps the phone-side items, then the hub files still ticked in their
    /// old order, then the new ones in the order the hub listed them.
    private func apply() {
        let others = attachments.filter { !$0.isHubFile }
        let kept = attachments.filter { item in item.hubPath.map(picked.contains) ?? false }
        let keptPaths = Set(kept.compactMap { $0.hubPath })
        let added = files.filter { picked.contains($0) && !keptPaths.contains($0) }
            .map { AttachmentItem.forHubPath($0) }
        attachments = others + kept + added
        dismiss()
    }
}
