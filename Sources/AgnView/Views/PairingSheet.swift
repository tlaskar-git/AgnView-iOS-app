import SwiftUI

/// The pairing flow: scan or paste, then success or a plain failure message.
/// The scanned text and the key never appear on screen.
struct PairingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                switch model.pairingResult {
                case .idle:
                    scanView
                case .success(let name):
                    successView(name: name)
                case .failure(let error):
                    failureView(error: error)
                }
            }
            .background(Theme.page.ignoresSafeArea())
            .navigationTitle("Add machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("pairing-close")
                }
            }
        }
        .onAppear { model.pairingResult = .idle }
    }

    private var scanView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan the QR code shown in AgnView on your computer, or paste the pairing link.")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal)
            QRScannerView(onScan: { text in model.pair(text: text) })
                .id(attempt)
        }
        .padding(.top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairing-scan")
    }

    private func successView(name: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(Theme.success)
                .accessibilityHidden(true)
            Text("Paired with " + name)
                .font(.title2.bold())
                .foregroundStyle(Theme.textMain)
                .multilineTextAlignment(.center)
            if model.connection.isOnline {
                Text("Connected over " + model.route.label)
                    .foregroundStyle(Theme.textSecondary)
            } else if case .connecting = model.connection {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Connecting")
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if let message = model.statusMessage {
                Text(message)
                    .foregroundStyle(Theme.warning)
                    .multilineTextAlignment(.center)
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.action)
                .controlSize(.large)
                .accessibilityIdentifier("pairing-done")
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairing-success")
    }

    private func failureView(error: PairingError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(Theme.error)
                .accessibilityHidden(true)
            Text("Pairing failed")
                .font(.title2.bold())
                .foregroundStyle(Theme.textMain)
            Text(error.userMessage)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") {
                model.pairingResult = .idle
                attempt += 1
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.action)
            .controlSize(.large)
            .accessibilityIdentifier("pairing-retry")
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pairing-failure")
    }
}
