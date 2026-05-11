// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AVFoundation

struct PairView: View {
    let onPaired: (DeviceCredentials) -> Void

    enum Mode: Equatable {
        case choose
        case scan
        case paste
    }

    @State private var mode: Mode = .choose
    @State private var redeeming = false
    @State private var error: String? = nil
    @State private var pasteText: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(NSLocalizedString("pair.title", comment: ""))
                        .font(.title2.bold())
                        .foregroundStyle(PapercupTheme.text)
                    Text(
                        "Open the desktop operator at /settings/mobile, mint a pair token, " +
                        "and either scan the QR or paste the payload below."
                    )
                    .font(.callout)
                    .foregroundStyle(PapercupTheme.textMuted)
                }
                .papercupCardRow()

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote.monospaced())
                            .foregroundStyle(PapercupTheme.error)
                    }
                    .papercupCardRow(accent: PapercupTheme.error.opacity(0.14))
                }

                switch mode {
                case .choose:
                    Section {
                        Button("Scan QR code") { mode = .scan }
                            .buttonStyle(.borderedProminent)
                        Button("Paste payload") { mode = .paste }
                            .buttonStyle(.bordered)
                    }
                    .papercupCardRow()
                case .scan:
                    Section {
                        QRScannerView(disabled: redeeming) { raw in redeem(raw: raw) }
                            .frame(height: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PapercupTheme.accent.opacity(0.45), lineWidth: 1))
                        Button("Back") { mode = .choose }
                    }
                    .papercupCardRow()
                case .paste:
                    Section {
                        TextEditor(text: $pasteText)
                            .frame(minHeight: 120)
                            .font(.footnote.monospaced())
                            .disabled(redeeming)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(PapercupTheme.inkRaised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        HStack {
                            Button("Back") { mode = .choose }
                            Spacer()
                            Button("Pair") { redeem(raw: pasteText) }
                                .buttonStyle(.borderedProminent)
                                .disabled(redeeming || pasteText.isEmpty)
                        }
                    }
                    .papercupCardRow()
                }

                if redeeming {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(NSLocalizedString("loading", comment: "")).font(.footnote)
                        }
                    }
                    .papercupCardRow(accent: PapercupTheme.info.opacity(0.10))
                }
            }
            .papercupScreenChrome()
            .navigationTitle("Mobile access")
        }
    }

    private func redeem(raw: String) {
        guard !redeeming else { return }
        redeeming = true
        error = nil
        Task {
            defer { redeeming = false }
            do {
                let payload = try parseQrPayload(text: raw)
                let keys = generateWgKeypair()
                let client = OperatorClient(baseUrl: payload.server, deviceToken: nil)
                let outcome = try await client.pair(
                    pairToken: payload.pairToken,
                    wireguardPubkeyB64: keys.publicKeyB64
                )
                let wgQuick = outcome.mesh.map { meshToWgQuick(privateKeyB64: keys.privateKeyB64, config: $0) }
                onPaired(DeviceCredentials(
                    server: payload.server,
                    deviceToken: outcome.deviceToken,
                    deviceId: outcome.deviceId,
                    workspaceId: outcome.workspaceId,
                    meshAssignedIp: outcome.mesh?.assignedIp,
                    wgQuickConfig: wgQuick,
                    wgPrivateKey: outcome.mesh != nil ? keys.privateKeyB64 : nil,
                    meshUrl: outcome.desktopMeshUrl
                ))
            } catch let err as PairError {
                if case .InvalidQr(_) = err {
                    error = "That payload doesn't look right — expected JSON with " +
                        "server, pairToken, workspaceId."
                } else {
                    error = "Pair failed: \(err)"
                }
            } catch let e {
                error = "Pair failed: \(e)"
            }
        }
    }
}

// MARK: - QR scanner (AVFoundation)

private struct QRScannerView: UIViewControllerRepresentable {
    let disabled: Bool
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onPayload = onPayload
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {
        vc.disabled = disabled
    }
}

private final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onPayload: ((String) -> Void)?
    var disabled: Bool = false
    private var session: AVCaptureSession?
    private var consumed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupSession()
    }

    private func setupSession() {
        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return }
        let session = AVCaptureSession()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        self.session = session
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        view.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }.forEach {
            $0.frame = view.layer.bounds
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !consumed, !disabled else { return }
        guard
            let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let raw = obj.stringValue
        else { return }
        consumed = true
        onPayload?(raw)
    }
}
