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
        ZStack {
            PapercupTheme.screenGradient.ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    PapercuspWordmark()
                        .frame(width: 256, height: 84)
                        .accessibilityLabel(Text("Papercusp"))
                        .accessibilityAddTraits(.isImage)
                    Text("MISSION CONSOLE")
                        .font(.caption2.weight(.semibold))
                        .tracking(1.4)
                        .foregroundStyle(PapercupTheme.accentStrong.opacity(0.62))
                }

                Text("Pair with your desktop")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(PapercupTheme.text)

                switch mode {
                case .choose:
                    Text("On your desktop: Settings → Mobile Access → \"Pair new device\" → scan the QR code shown.")
                        .font(.callout)
                        .foregroundStyle(PapercupTheme.textMuted)
                        .frame(maxWidth: 320)

                    PrimaryPairButton(title: redeeming ? "Pairing…" : "Scan QR", disabled: redeeming) {
                        mode = .scan
                    }
                    SecondaryPairButton(title: "Paste manually", disabled: redeeming) {
                        mode = .paste
                    }

                case .scan:
                    QRScannerView(disabled: redeeming) { raw in redeem(raw: raw) }
                        .frame(maxWidth: 360, minHeight: 360, maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(PapercupTheme.accent.opacity(0.45), lineWidth: 1)
                        )
                    HStack(spacing: 12) {
                        Button("Back") { mode = .choose }
                            .buttonStyle(.bordered)
                        Button("Paste manually") { mode = .paste }
                            .buttonStyle(.bordered)
                    }

                case .paste:
                    VStack(alignment: .leading, spacing: 12) {
                        PapercupSectionTitle(text: NSLocalizedString("pair.pastePayload", comment: ""))
                        TextEditor(text: $pasteText)
                            .frame(minHeight: 120)
                            .font(.footnote.monospaced())
                            .foregroundColor(PapercupTheme.text)
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
                    .papercupCardContainer()
                }

                if redeeming {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(NSLocalizedString("loading", comment: "")).font(.footnote)
                    }
                    .foregroundStyle(PapercupTheme.textMuted)
                }

                if let error {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error)
                            .font(.footnote.monospaced())
                            .foregroundStyle(PapercupTheme.error)
                        Button(redeeming ? "Retrying…" : "Try again") {
                            if mode == .paste {
                                redeem(raw: pasteText)
                            } else {
                                mode = .scan
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(redeeming)
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                    .padding(12)
                    .background(PapercupTheme.cardBackground(accent: PapercupTheme.error.opacity(0.16)))
                }

                HStack(spacing: 20) {
                    Link("Privacy", destination: AppLinks.privacy)
                    Link("Support", destination: AppLinks.support)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(PapercupTheme.accentStrong)
            }
            .padding(.horizontal, 32)
            .multilineTextAlignment(.center)
        }
        .tint(PapercupTheme.accent)
    }

    private func redeem(raw: String) {
        guard !redeeming else { return }
        redeeming = true
        error = nil
        Task {
            defer { redeeming = false }
            do {
                let payload = try parseQrPayload(text: raw)
                let client = OperatorClient(baseUrl: payload.server, deviceToken: nil)
                // Mesh is Defguard self-enrollment now (D-005): no WG
                // keypair at pair time; the response carries an enrollment
                // URL the user opens to join the mesh.
                let outcome = try await client.pair(pairToken: payload.pairToken)
                onPaired(DeviceCredentials(
                    server: payload.server,
                    deviceToken: outcome.deviceToken,
                    deviceId: outcome.deviceId,
                    workspaceId: outcome.workspaceId,
                    defguardEnrollmentUrl: outcome.defguardEnrollmentUrl
                ))
            } catch let err as PairError {
                if case .InvalidQr(_) = err {
                    error = "That payload doesn't look right — expected JSON with " +
                        "server, pairToken, workspaceId."
                } else {
                    error = FriendlyError.message(err, doing: "pairing")
                }
            } catch let e {
                error = FriendlyError.message(e, doing: "pairing")
            }
        }
    }
}

private struct PrimaryPairButton: View {
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PapercupTokens.primaryButtonText)
                .frame(minWidth: 144, minHeight: 46)
                .padding(.horizontal, 20)
                .background(
                    LinearGradient(
                        colors: [
                            PapercupTokens.primaryButtonGradTop,
                            PapercupTokens.accent,
                            PapercupTokens.primaryButtonGradBottom,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(PapercupTheme.accentStrong.opacity(0.48), lineWidth: 1))
                .shadow(color: PapercupTheme.accent.opacity(0.18), radius: 18, x: 0, y: 10)
                .opacity(disabled ? 0.56 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct SecondaryPairButton: View {
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PapercupTheme.accentStrong)
                .frame(minWidth: 144, minHeight: 46)
                .padding(.horizontal, 20)
                .background(PapercupTheme.accent.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(PapercupTheme.accentStrong.opacity(0.48), lineWidth: 1))
                .opacity(disabled ? 0.56 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

private struct PapercuspWordmark: View {
    var body: some View {
        Image("PairingWordmark")
            .resizable()
            .scaledToFit()
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
