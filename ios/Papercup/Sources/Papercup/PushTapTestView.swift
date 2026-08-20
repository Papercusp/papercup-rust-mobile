// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import PapercupCore

enum PushTapTestRoute: Equatable {
    case harnessDetail(String)
    case runLog(String)
    case operatorTab
    case inbox
}

struct PushTapTestView: View {
    let onNavigate: (PushTapTestRoute) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                screenHeader
                VStack(spacing: 8) {
                    ForEach(PushTapTestSample.samples) { sample in
                        Button {
                            onNavigate(sample.route)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(sample.label)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(PapercupTheme.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("payload: \(sample.payload)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(PapercupTheme.textMuted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("→ \(sample.expectedRoute)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(PapercupTheme.accentStrong)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(14)
                            .background(PapercupTheme.cardBackground(accent: PapercupTheme.info.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("\(sample.label). \(sample.expectedRoute)"))
                    }
                }
                Text("Buttons run the same native push-tap route mapping this shell uses. Real push delivery still depends on APNs registration and a server-sent notification.")
                    .font(.caption2)
                    .foregroundStyle(PapercupTheme.textMuted)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 112)
        }
        .papercupScreenChrome()
        .navigationTitle("Push tap test")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var screenHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Push tap test")
                .font(.title2.weight(.semibold))
                .foregroundStyle(PapercupTheme.text)
            Text("Simulates a tapped notification and runs the same in-app route the native handler uses.")
                .font(.caption)
                .foregroundStyle(PapercupTheme.textMuted)
        }
        .padding(.vertical, 10)
    }
}

private struct PushTapTestSample: Identifiable {
    let id: String
    let label: String
    let payload: String
    let expectedRoute: String
    let route: PushTapTestRoute

    static let samples: [PushTapTestSample] = [
        .init(
            id: "intervention-harness",
            label: "intervention (harness=foo)",
            payload: #"{"kind":"intervention","harness":"foo"}"#,
            expectedRoute: "/harness/foo",
            route: .harnessDetail("foo")
        ),
        .init(
            id: "intervention-empty",
            label: "intervention (no harness)",
            payload: #"{"kind":"intervention"}"#,
            expectedRoute: "/notifications",
            route: .inbox
        ),
        .init(
            id: "plan-review-harness",
            label: "plan-review (harness=bar)",
            payload: #"{"kind":"plan-review","harness":"bar"}"#,
            expectedRoute: "/harness/bar",
            route: .harnessDetail("bar")
        ),
        .init(
            id: "plan-review-empty",
            label: "plan-review (no harness)",
            payload: #"{"kind":"plan-review"}"#,
            expectedRoute: "/notifications",
            route: .inbox
        ),
        .init(
            id: "smoke-fail-harness",
            label: "smoke-fail (harness=baz)",
            payload: #"{"kind":"smoke-fail","harness":"baz"}"#,
            expectedRoute: "/log/baz",
            route: .runLog("baz")
        ),
        .init(
            id: "smoke-fail-empty",
            label: "smoke-fail (no harness)",
            payload: #"{"kind":"smoke-fail"}"#,
            expectedRoute: "/notifications",
            route: .inbox
        ),
        .init(
            id: "operator-suggestion",
            label: "operator-suggestion",
            payload: #"{"kind":"operator-suggestion"}"#,
            expectedRoute: "/operator",
            route: .operatorTab
        ),
        .init(
            id: "unknown",
            label: "unknown kind",
            payload: #"{"kind":"mystery"}"#,
            expectedRoute: "/notifications",
            route: .inbox
        ),
        .init(
            id: "empty",
            label: "empty payload",
            payload: #"{}"#,
            expectedRoute: "/notifications",
            route: .inbox
        ),
    ]
}
