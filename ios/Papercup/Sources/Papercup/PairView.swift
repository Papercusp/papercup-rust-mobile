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
                PapercuspWordmark()
                    .frame(width: 256, height: 84)
                    .accessibilityLabel(Text("Papercusp"))
                    .accessibilityAddTraits(.isImage)

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
                        Button("Paste payload") { mode = .paste }
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

private struct PrimaryPairButton: View {
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(red: 0.01, green: 0.07, blue: 0.09))
                .frame(minWidth: 144, minHeight: 46)
                .padding(.horizontal, 20)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.83, green: 0.98, blue: 1.0),
                            PapercupTheme.accent,
                            Color(red: 0.03, green: 0.57, blue: 0.70),
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

private struct PapercuspWordmark: View {
    private let cream = Color(red: 0.95, green: 0.93, blue: 0.98)
    private let porcelain = Color(red: 1.0, green: 0.96, blue: 0.88)
    private let gold = Color(red: 0.83, green: 0.64, blue: 0.45)

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 520, size.height / 170)
            let dx = (size.width - 520 * scale) / 2
            let dy = (size.height - 170 * scale) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: dx + x * scale, y: dy + y * scale)
            }
            func cp(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                p(260 + x * 1.08, 104 + y * 1.08)
            }
            func ellipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) -> Path {
                Path(ellipseIn: CGRect(
                    x: dx + (cx - rx) * scale,
                    y: dy + (cy - ry) * scale,
                    width: rx * 2 * scale,
                    height: ry * 2 * scale
                ))
            }

            var antennaLeft = Path()
            antennaLeft.move(to: p(260, 20))
            antennaLeft.addCurve(to: p(214, 86), control1: p(260, 54), control2: p(238, 72))
            var antennaRight = Path()
            antennaRight.move(to: p(260, 20))
            antennaRight.addCurve(to: p(306, 86), control1: p(260, 54), control2: p(282, 72))
            let antennaStroke = StrokeStyle(lineWidth: 5 * scale, lineCap: .round)
            context.stroke(antennaLeft, with: .color(cream.opacity(0.96)), style: antennaStroke)
            context.stroke(antennaRight, with: .color(cream.opacity(0.96)), style: antennaStroke)
            context.fill(ellipse(cx: 260, cy: 104, rx: 70, ry: 58), with: .color(gold.opacity(0.08)))

            var cup = Path()
            cup.move(to: cp(-48, -20))
            cup.addLine(to: cp(-42, 42))
            cup.addQuadCurve(to: cp(0, 50), control: cp(-42, 50))
            cup.addQuadCurve(to: cp(42, 42), control: cp(42, 50))
            cup.addLine(to: cp(48, -20))
            cup.closeSubpath()
            context.fill(cup, with: .color(porcelain.opacity(0.20)))
            context.stroke(
                cup,
                with: .color(cream.opacity(0.46)),
                style: StrokeStyle(lineWidth: 3.2 * scale, lineJoin: .round)
            )

            let rimOuter = ellipse(cx: 260, cy: 104 - 20 * 1.08, rx: 48 * 1.08, ry: 9.5 * 1.08)
            context.fill(rimOuter, with: .color(porcelain.opacity(0.20)))
            context.stroke(rimOuter, with: .color(cream.opacity(0.46)), lineWidth: 3.2 * scale)
            context.fill(
                ellipse(cx: 260, cy: 104 - 20 * 1.08, rx: 39.5 * 1.08, ry: 6.9 * 1.08),
                with: .color(gold.opacity(0.48))
            )

            var smile = Path()
            smile.move(to: cp(-39, 16))
            smile.addQuadCurve(to: cp(39, 16), control: cp(0, 8))
            context.stroke(smile, with: .color(gold.opacity(0.62)), style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round))

            var leftBrow = Path()
            leftBrow.move(to: cp(-24, 13))
            leftBrow.addQuadCurve(to: cp(-6, 12), control: cp(-15, 5))
            context.stroke(leftBrow, with: .color(cream.opacity(0.52)), style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round))
            var rightBrow = Path()
            rightBrow.move(to: cp(6, 12))
            rightBrow.addQuadCurve(to: cp(24, 13), control: cp(15, 5))
            context.stroke(rightBrow, with: .color(cream.opacity(0.52)), style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round))

            for x in [CGFloat(-16), CGFloat(16)] {
                context.fill(ellipse(cx: 260 + x * 1.08, cy: 104 + 29 * 1.08, rx: 7.2 * 1.08, ry: 7.2 * 1.08), with: .color(porcelain.opacity(0.20)))
                context.stroke(ellipse(cx: 260 + x * 1.08, cy: 104 + 29 * 1.08, rx: 7.2 * 1.08, ry: 7.2 * 1.08), with: .color(cream.opacity(0.46)), lineWidth: 2 * scale)
                context.fill(ellipse(cx: 260 + x * 1.08, cy: 104 + 25 * 1.08, rx: 2.9 * 1.08, ry: 2.9 * 1.08), with: .color(cream.opacity(0.62)))
            }
            context.fill(ellipse(cx: 260, cy: 104 + 39 * 1.08, rx: 4.4 * 1.08, ry: 6.2 * 1.08), with: .color(cream.opacity(0.46)))

            context.draw(
                Text("papercusp")
                    .font(.system(size: 69 * scale, weight: .bold))
                    .foregroundStyle(cream.opacity(0.96)),
                at: p(260, 130),
                anchor: .center
            )
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
