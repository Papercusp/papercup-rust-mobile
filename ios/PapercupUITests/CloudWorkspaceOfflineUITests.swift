// SPDX-License-Identifier: GPL-3.0-or-later
//
// P-015 (iphone-public-release D-014): a phone paired to a BYOC cloud
// workspace must say the CLOUD WORKSPACE is offline while its connector is
// down, and reconnect by itself once the connector returns, without ever
// dropping to pairing. The hosted relay reports a stopped or starting
// workspace with HTTP 503 {"error":"workspace_offline"} plus Retry-After
// (papercusp hosted-app-relay.ts).
//
// This test stands that relay up in-process: an NWListener on 127.0.0.1
// answers the app's device API, first as an offline workspace and then as a
// healthy one. The simulator shares the host loopback, and Info.plist sets
// NSAllowsLocalNetworking, so the app reaches it over plain HTTP.
// Credentials are seeded through the DEBUG seedCredentials launch argument,
// so no backend pairing is needed and the test runs on every CI build.

import Network
import XCTest

/// Minimal HTTP/1.1 stand-in for the hosted relay: one request per
/// connection, answered and closed (`Connection: close`).
final class RelayStub {
    enum Mode { case workspaceOffline, online, transportFailure, unauthorized, forbidden }

    private let queue = DispatchQueue(label: "com.papercuspai.uitests.relay-stub")
    private let listener: NWListener
    private let lock = NSLock()
    private var mode: Mode
    private var heartbeats: [Mode: Int] = [:]

    init(initialMode: Mode = .workspaceOffline) throws {
        mode = initialMode
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    /// Start listening and return the bound loopback port.
    func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 10)
        guard case .ready = listener.state, let port = listener.port?.rawValue, port != 0 else {
            throw NSError(domain: "RelayStub", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "relay stub did not start: \(listener.state)",
            ])
        }
        return port
    }

    func stop() {
        listener.cancel()
    }

    func setMode(_ newMode: Mode) {
        lock.lock()
        mode = newMode
        lock.unlock()
    }

    func heartbeatCount(in m: Mode) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return heartbeats[m, default: 0]
    }

    // ── connection handling ───────────────────────────────────────────

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    /// Accumulate until the head and any Content-Length body have arrived,
    /// so closing after the response never resets unread request bytes.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let request = Self.parse(buf) {
                self.respond(conn, path: request)
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    /// Returns the request path once the full request is buffered.
    private static func parse(_ buf: Data) -> String? {
        guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[buf.startIndex ..< headEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard buf.distance(from: headEnd.upperBound, to: buf.endIndex) >= contentLength else { return nil }
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return "/" }
        return String(requestLine[1].split(separator: "?").first ?? "/")
    }

    private func respond(_ conn: NWConnection, path: String) {
        lock.lock()
        let current = mode
        let isHeartbeat = path == "/api/device/heartbeat"
        if isHeartbeat { heartbeats[current, default: 0] += 1 }
        lock.unlock()

        if current == .transportFailure {
            conn.cancel()
            return
        }

        let status: String
        let body: String
        var extraHeaders = ""
        switch current {
        case .unauthorized:
            status = "401 Unauthorized"
            body = #"{"error":"invalid_or_expired_token"}"#
        case .forbidden:
            status = "403 Forbidden"
            body = #"{"error":"device_revoked"}"#
        case .transportFailure:
            return // Handled by closing the transport above, without an HTTP response.
        case .workspaceOffline:
            // The relay's exact refusal for a stopped or starting workspace.
            status = "503 Service Unavailable"
            body = #"{"error":"workspace_offline"}"#
            extraHeaders = "Retry-After: 30\r\n"
        case .online where isHeartbeat:
            status = "200 OK"
            body = #"{"ok":true}"#
        case .online:
            // Never 401/403: those mean a revoked device and would
            // legitimately send the app back to pairing.
            status = "404 Not Found"
            body = #"{"error":"not_found"}"#
        }
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + extraHeaders
            + "Connection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bodyData, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

final class CloudWorkspaceOfflineUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func retainScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchPairedApp(port: UInt16) throws -> XCUIApplication {
        let creds = ["server": "http://127.0.0.1:\(port)",
                     "deviceToken": "uitest-recovery-token", "deviceId": "uitest-recovery-device",
                     "workspaceId": "uitest-recovery-workspace"]
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: creds), encoding: .utf8))
        let app = XCUIApplication()
        app.launchArguments = ["-com.papercuspai.uitests.wipeCredentials", "YES",
                               "-com.papercuspai.uitests.seedCredentials", json]
        app.launch()
        return app
    }

    private func waitForHeartbeat(_ relay: RelayStub, mode: RelayStub.Mode, after count: Int = 0) {
        let received = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            relay.heartbeatCount(in: mode) > count
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 30), .completed,
                       "the actual native heartbeat must reach the selected backend state")
    }

    /// P-008 native UI contract: an actual transport failure preserves pairing,
    /// and a successful heartbeat recovers without writing credentials again.
    /// This controlled responder proves client behavior, not public/LAN routing.
    func testTransportFailureRecoversWithoutRepairing() throws {
        let relay = try RelayStub(initialMode: .online)
        let port = try relay.start()
        defer { relay.stop() }
        let app = try launchPairedApp(port: port)
        waitForHeartbeat(relay, mode: .online)

        relay.setMode(.transportFailure)
        XCUIDevice.shared.press(.home)
        app.activate()
        let title = app.staticTexts["offline-banner-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30))
        XCTAssertEqual(title.label, "Desktop offline")
        XCTAssertGreaterThan(relay.heartbeatCount(in: .transportFailure), 0)
        XCTAssertFalse(app.buttons["pairAgainButton"].exists)
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists)
        retainScreenshot(app, named: "transport-offline-keeps-pairing")

        let before = relay.heartbeatCount(in: .online)
        relay.setMode(.online)
        XCUIDevice.shared.press(.home)
        app.activate()
        let cleared = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: title)
        wait(for: [cleared], timeout: 45)
        waitForHeartbeat(relay, mode: .online, after: before)
        XCTAssertFalse(app.buttons["pairAgainButton"].exists)
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists)
        retainScreenshot(app, named: "transport-recovered-without-repairing")

        // An ordinary launch must still load the saved pairing. A seed hook
        // on this launch would hide accidental credential deletion on failure.
        let beforeRelaunch = relay.heartbeatCount(in: .online)
        app.terminate()
        app.launchArguments = []
        app.launch()
        waitForHeartbeat(relay, mode: .online, after: beforeRelaunch)
        XCTAssertTrue(app.staticTexts["Needs you"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists)
    }

    /// Both HTTP refusal shapes must offer Pair again, rather than an offline
    /// loop. The real backend's expiry/signature/revocation enforcement is a
    /// separate integration contract; this responder only controls its reply.
    func testAuthorizationRefusalOffersPairAgainAndClearsKeychain() throws {
        for (mode, label) in [(RelayStub.Mode.unauthorized, "unauthorized"), (.forbidden, "forbidden")] {
            let relay = try RelayStub(initialMode: .online)
            let port = try relay.start()
            defer { relay.stop() }
            let app = try launchPairedApp(port: port)
            waitForHeartbeat(relay, mode: .online)
            XCTAssertFalse(app.buttons["pairAgainButton"].exists)

            relay.setMode(mode)
            XCUIDevice.shared.press(.home)
            app.activate()
            let pairAgain = app.buttons["pairAgainButton"]
            XCTAssertTrue(pairAgain.waitForExistence(timeout: 30), "\(label) must offer re-pairing")
            XCTAssertGreaterThan(relay.heartbeatCount(in: mode), 0)
            XCTAssertFalse(app.staticTexts["offline-banner-title"].exists,
                           "an answered authorization refusal is not a transport outage")
            XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists)
            retainScreenshot(app, named: "\(label)-offers-pair-again")

            pairAgain.tap()
            XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["Paste manually"].exists)
            retainScreenshot(app, named: "\(label)-returned-to-remote-access-pairing")
            app.terminate()
            app.launchArguments = []
            app.launch()
            XCTAssertTrue(app.staticTexts["Pair with your desktop"].waitForExistence(timeout: 10),
                          "Pair again must clear Keychain credentials across an ordinary relaunch")
            app.terminate()
        }
    }

    /// Spec clauses BYOC-P-015-offline-message and
    /// BYOC-P-015-offline-recovery.
    func testCloudWorkspaceOfflineThenRecoversWithoutRepairing() throws {
        let relay = try RelayStub()
        let port = try relay.start()
        defer { relay.stop() }

        let creds: [String: String] = [
            "server": "http://127.0.0.1:\(port)",
            "deviceToken": "uitest-cloud-device-token",
            "deviceId": "uitest-cloud-device",
            "workspaceId": "uitest-cloud-workspace",
        ]
        let credsJson = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: creds),
            encoding: .utf8
        ))

        let app = XCUIApplication()
        app.launchArguments = [
            "-com.papercuspai.uitests.wipeCredentials", "YES",
            "-com.papercuspai.uitests.seedCredentials", credsJson,
        ]
        app.launch()

        // 1. Connector down: the banner names the cloud workspace, not the
        //    desktop, and the pairing is kept.
        let title = app.staticTexts["offline-banner-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 30),
                      "offline banner should appear while the relay answers workspace_offline")
        XCTAssertEqual(title.label, "Cloud workspace offline")
        XCTAssertGreaterThan(relay.heartbeatCount(in: .workspaceOffline), 0,
                             "the banner must come from the stub relay's refusal")
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists,
                       "a stopped cloud workspace must not drop the phone to pairing")
        XCTAssertFalse(app.buttons["pairAgainButton"].exists,
                       "workspace_offline is reachability, not a revoked device")
        retainScreenshot(app, named: "cloud-workspace-offline")

        // 2. Connector back: the app reconnects by itself. Returning to the
        //    foreground re-probes at once instead of waiting out the 20 s
        //    heartbeat period; either path must clear the banner.
        relay.setMode(.online)
        XCUIDevice.shared.press(.home)
        app.activate()
        let cleared = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: title)
        wait(for: [cleared], timeout: 45)
        XCTAssertGreaterThan(relay.heartbeatCount(in: .online), 0,
                             "recovery must be a fresh successful heartbeat")
        XCTAssertFalse(app.staticTexts["Pair with your desktop"].exists,
                       "recovery must not require re-pairing")
        XCTAssertFalse(app.buttons["pairAgainButton"].exists)
        retainScreenshot(app, named: "cloud-workspace-recovered")
    }

    /// D-018: a credential whose stored route list carries a kind `relay`
    /// entry is a cloud (BYOC) workspace, and Settings says so instead of
    /// "public tunnel / LAN". The label derives from the persisted pair-time
    /// `baseUrls`, so no backend round-trip is needed.
    func testCloudWorkspaceShowsRelayLabelInSettings() throws {
        let relay = try RelayStub()
        let port = try relay.start()
        defer { relay.stop() }

        let routes = #"[{"kind":"relay","url":"http://127.0.0.1:\#(port)"}]"#
        let creds: [String: String] = [
            "server": "http://127.0.0.1:\(port)",
            "deviceToken": "uitest-cloud-device-token",
            "deviceId": "uitest-cloud-device",
            "workspaceId": "uitest-cloud-workspace",
            "baseUrlsJson": routes,
        ]
        let credsJson = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: creds),
            encoding: .utf8
        ))

        let app = XCUIApplication()
        app.launchArguments = [
            "-com.papercuspai.uitests.wipeCredentials", "YES",
            "-com.papercuspai.uitests.seedCredentials", credsJson,
        ]
        app.launch()

        func element(labelContaining text: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
                .firstMatch
        }

        let settingsTab = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Settings"))
            .firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 30),
                      "seeded credentials should mount the paired shell")
        settingsTab.tap()

        let label = element(labelContaining: "Cloud workspace (relay)")
        var swipes = 0
        while !label.waitForExistence(timeout: 3) && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(label.exists,
                      "Settings should label a relay-routed credential as a cloud workspace")
        XCTAssertFalse(element(labelContaining: "public tunnel / LAN").exists,
                       "a cloud workspace must not be described as a desktop tunnel / LAN")
        retainScreenshot(app, named: "cloud-workspace-relay-label")
    }
}
