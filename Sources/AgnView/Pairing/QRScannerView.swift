import SwiftUI
import AVFoundation

/// Why the camera cannot be used.
enum ScannerIssue: Equatable {
    case permissionDenied
    case noCamera

    var message: String {
        switch self {
        case .permissionDenied:
            return "Camera access is off. Allow it in Settings, or paste the pairing link below."
        case .noCamera:
            return "No camera is available. Paste the pairing link below."
        }
    }
}

/// Scans a pairing QR code. Calls onScan once with the scanned text. The text is never logged.
/// Without a camera or permission, a paste field feeds the same closure.
struct QRScannerView: View {
    let onScan: (String) -> Void

    @State private var issue: ScannerIssue?
    @State private var pasted: String = ""
    @State private var delivered = false

    var body: some View {
        VStack(spacing: 16) {
            if let issue {
                Text(issue.message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, minHeight: 200)
                    .accessibilityIdentifier("scanner-issue")
            } else {
                QRCameraView(onCode: deliver, onIssue: { issue = $0 })
                    .frame(minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("scanner-camera")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Paste pairing link").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    TextField("agnview://pair?...", text: $pasted)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("scanner-paste-field")
                    Button("Use") { deliver(pasted) }
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("scanner-paste-button")
                }
            }
        }
        .padding()
    }

    private func deliver(_ text: String) {
        guard !delivered else { return }
        delivered = true
        onScan(text)
    }
}

struct QRCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onIssue: (ScannerIssue) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.onCode = onCode
        vc.onIssue = onIssue
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onIssue: ((ScannerIssue) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "agnview.qr.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var configured = false
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureAndStart() } else { self?.onIssue?(.permissionDenied) }
                }
            }
        default:
            onIssue?(.permissionDenied)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    private func configureAndStart() {
        guard !configured else { return }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onIssue?(.noCamera)
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onIssue?(.noCamera)
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        configured = true
        let session = self.session
        sessionQueue.async { session.startRunning() }
    }

    private func stop() {
        let session = self.session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !finished,
              let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let text = obj.stringValue else { return }
        finished = true
        stop()
        onCode?(text)
    }
}
