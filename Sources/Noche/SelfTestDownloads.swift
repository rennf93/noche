#if NOCHE_TESTHOOKS
import AppKit
import CefBridge

/// Bridge checks of M1.5 Task 2: downloads and permission requests. Every request is answered deny, every download is written to a temporary folder.
@MainActor
final class DownloadSink: NSObject, NCDownloadsObserver {
    var updates: [NCDownloadItem] = []
    func downloads(_ downloads: NCDownloads, didUpdate item: NCDownloadItem) { updates.append(item) }
}

extension BrowserWindowController {
    /// Self-test builds answer permission requests through the running check; the production controller gets its own implementation with the prompt card (M1.5 Task 4).
    func window(_ window: NCWindow, tab: NCTab, requestsPermissions mask: NCPermissionMask, origin: String, decide: @escaping (Bool, Bool) -> Void) {
        guard let test = app.selfTest else { return }
        test.permissionRequests.append((mask, origin))
        let answer = test.permissionAnswer(mask)
        decide(answer.allow, answer.remember)
    }
}

/// A local server that trickles a 40 MB file (16 KB every 20 ms), so a download stays in progress long enough to pause. The one process it starts is stopped by its PID.
final class SlowServer: @unchecked Sendable {
    let process = Process()
    private(set) var port = 0

    static func start() async -> SlowServer? {
        let server = SlowServer()
        let out = Pipe()
        server.process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.process.arguments = ["-I", "-c", """
        import http.server, time
        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', '40000000')
                self.end_headers()
                try:
                    for _ in range(2500):
                        self.wfile.write(b'x' * 16384); self.wfile.flush(); time.sleep(0.02)
                except Exception:
                    pass
            def log_message(self, *a): pass
        s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
        print(s.server_address[1], flush=True)
        s.serve_forever()
        """]
        server.process.standardOutput = out
        guard (try? server.process.run()) != nil else { return nil }
        let first = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async { c.resume(returning: String(data: out.fileHandleForReading.availableData, encoding: .utf8) ?? "") }
        }
        guard let port = Int(first.trimmingCharacters(in: .whitespacesAndNewlines)) else { server.stop(); return nil }
        server.port = port
        return server
    }

    func stop() { if process.isRunning { process.terminate() } }
}

extension SelfTest {
    /// Never allow: a test run must not reach a macOS permission dialog (camera, microphone, location, notifications).
    func permissionAnswer(_ mask: NCPermissionMask) -> (allow: Bool, remember: Bool) { (false, true) }

    func tempFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("noche-bridge-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func listing(_ dir: URL) -> Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []) }

    func bridgeDl() async {
        guard await ready(), let win, let tab = win.activeTab else { return }
        // The check's own folder, before any download: nothing a test downloads may land in the owner's Downloads.
        let dir = tempFolder()
        defer { try? FileManager.default.removeItem(at: dir) }
        do { try NCEngine.setDownloadDirectory(dir.path) } catch { return finish(false, "setDownloadDirectory refused \(dir.path): \(error)") }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let homeBefore = listing(home)
        let sink = DownloadSink()
        NCDownloads.shared.start(observer: sink)
        let source = fixture("download.bin")
        guard let (expected, _) = try? await URLSession.shared.data(from: URL(string: source)!) else { return finish(false, "the fixture server did not serve download.bin") }
        tab.loadURL(source)
        guard await until(20, { sink.updates.contains { $0.state == .complete } }) else {
            return finish(false, "no complete update reached the observer (updates: \(sink.updates.map { "\($0.state.rawValue):\($0.receivedBytes)/\($0.totalBytes)" }))")
        }
        let done = sink.updates.last { $0.state == .complete }!
        let same = sink.updates.filter { $0.identifier == done.identifier }
        let progress = same.filter { $0.state == .inProgress }
        let path = URL(fileURLWithPath: done.fullPath)
        let data = try? Data(contentsOf: path)
        let inFolder = path.resolvingSymlinksInPath().deletingLastPathComponent().path == dir.resolvingSymlinksInPath().path
        let kept = NCDownloads.shared.items.first { $0.identifier == done.identifier }
        try? await Task.sleep(for: .milliseconds(300))  // a stray file in the owner's folder would be written by now
        let homeAfter = listing(home)
        let ok = !progress.isEmpty && same.first?.state == .inProgress && done.suggestedName == "download.bin" && done.url == source
            && done.receivedBytes == Int64(expected.count) && done.totalBytes == Int64(expected.count) && done.percent == 100
            && inFolder && data == expected && kept?.state == .complete && homeAfter == homeBefore && violations.isEmpty
        let detail = "fixture download: \(same.count) updates (\(progress.count) in progress, first \(same.first?.state.rawValue ?? -1)), complete \(done.receivedBytes)/\(done.totalBytes) bytes \(done.percent)% as \(done.suggestedName) at \(done.fullPath) (in the check's folder \(inFolder), same bytes \(data == expected)), items() keeps it \(kept?.state == .complete), new files in ~/Downloads: \(homeAfter.subtracting(homeBefore).sorted()) \(violations)"
        guard ok else { return finish(false, detail) }
        line("info", detail)
        // A slow download (a local server that trickles 40 MB): pause, resume, pauseAllForQuit and cancel reach the engine and come back as states.
        guard let slow = await SlowServer.start() else { return finish(false, "the slow download server did not start") }
        defer { slow.stop() }
        let before = Set(sink.updates.map(\.identifier))
        tab.loadURL("http://127.0.0.1:\(slow.port)/slow.bin")
        func latest(_ id: UInt32) -> NCDownloadItem? { sink.updates.last { $0.identifier == id } }
        guard await until(15, { sink.updates.contains { !before.contains($0.identifier) && $0.state == .inProgress && $0.receivedBytes > 0 } }),
              let id = sink.updates.first(where: { !before.contains($0.identifier) })?.identifier else { return finish(false, "the slow download never made progress") }
        let nowPaused = { latest(id)?.state == .paused }
        NCDownloads.shared.pause(id)
        guard await until(10, nowPaused) else { return finish(false, "pause(id) did not end paused (state \(latest(id)?.state.rawValue ?? -1))") }
        let frozen = latest(id)!.receivedBytes
        try? await Task.sleep(for: .seconds(1.2))
        guard nowPaused(), latest(id)!.receivedBytes - frozen <= 262144 else { return finish(false, "a paused download kept receiving (\(frozen) to \(latest(id)!.receivedBytes) bytes, state \(latest(id)!.state.rawValue))") }
        NCDownloads.shared.resume(id)
        guard await until(15, { latest(id)?.state == .inProgress && latest(id)!.receivedBytes > frozen + 262144 }) else { return finish(false, "resume(id) did not continue the download (state \(latest(id)?.state.rawValue ?? -1), \(latest(id)!.receivedBytes) of \(frozen) bytes)") }
        let asked = NCDownloads.shared.pauseAllForQuit()
        guard asked == 1, await until(10, nowPaused) else { return finish(false, "pauseAllForQuit asked \(asked) pauses (wanted 1) and the download is \(latest(id)?.state.rawValue ?? -1)") }
        NCDownloads.shared.cancel(id)
        guard await until(10, { latest(id)?.state == .canceled }) else { return finish(false, "cancel(id) did not end canceled (state \(latest(id)?.state.rawValue ?? -1))") }
        finish(true, detail + "; slow download: paused (frozen at \(frozen) bytes), resumed, pauseAllForQuit asked \(asked) and paused it, canceled")
    }

    func bridgePerm() async {
        guard await ready(), let tab = win?.activeTab, let port = URL(string: url)?.port else { return }
        let origin = "http://127.0.0.1:\(port)"
        _ = await evaluate(tab, "navigator.geolocation.getCurrentPosition(() => { window.__geo = 'allowed' }, e => { window.__geo = 'error ' + e.code }); 1")
        guard await until(15, { permissionRequests.count >= 1 }) else { return finish(false, "no geolocation request reached the delegate") }
        let geo = permissionRequests[0]
        let geoReply = await pageValue(tab, "window.__geo")
        _ = await evaluate(tab, "Notification.requestPermission().then(p => { window.__notif = p }); 1")
        guard await until(15, { permissionRequests.count >= 2 }) else { return finish(false, "no notifications request reached the delegate (requests: \(permissionRequests))") }
        let notif = permissionRequests[1]
        let notifReply = await pageValue(tab, "window.__notif")
        let states = await evaluate(tab, "Promise.all([navigator.permissions.query({name: 'geolocation'}), navigator.permissions.query({name: 'notifications'})]).then(r => r.map(s => s.state).join())")
        let ok = permissionRequests.count == 2 && geo.mask == .geolocation && geo.origin == origin && notif.mask == .notifications && notif.origin == origin
            && geoReply == "\"error 1\"" && notifReply == "\"denied\"" && states == "\"denied,denied\"" && violations.isEmpty
        finish(ok, "geolocation (mask \(geo.mask.rawValue), \(geo.origin)) and notifications (mask \(notif.mask.rawValue), \(notif.origin)) reached the delegate, deny told the page: geolocation \(geoReply ?? "nil"), notifications \(notifReply ?? "nil"), permission states \(states ?? "nil") \(violations)")
    }

    /// The page's value (a JSON string) once the page has set it, polled; nil when it never did.
    func pageValue(_ tab: NCTab, _ expr: String) async -> String? {
        for _ in 0..<100 {
            if let v = await evaluate(tab, expr), v != "null", v != "undefined" { return v }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

extension SelfTest {
    func windowSummary() -> String {
        NSApp.windows.map { "\(NSStringFromClass(type(of: $0))) alpha=\($0.alphaValue) vis=\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height)) parent=\($0.parent != nil)" }.joined(separator: " | ")
    }

    /// First accessibility element under |node| (windows, views and Chromium's own nodes) whose role and title match.
    func axFind(_ node: Any, role: String, title: String, depth: Int = 0) -> NSAccessibilityProtocol? {
        guard depth < 14, let el = node as? NSAccessibilityProtocol else { return nil }
        if el.accessibilityRole()?.rawValue == role, el.accessibilityTitle() == title { return el }
        for child in el.accessibilityChildren() ?? [] { if let hit = axFind(child, role: role, title: title, depth: depth + 1) { return hit } }
        return nil
    }

    /// Chromium's "Save password?" bubble: the widget window of the app whose accessibility title says so.
    func passwordBubble() -> NSWindow? { NSApp.windows.first { NSStringFromClass(type(of: $0)).hasPrefix("NativeWidget") && $0.isVisible && $0.accessibilityTitle() == "Save password?" } }

    /// Chromium's own save prompt keeps working in the hidden app: a login form submitted on a fixture page raises the bubble (hidden, never key),
    /// its Save button is pressed through accessibility, and the next visit fills the saved credential. Dev and test builds use the mock keychain
    /// (MessagePump.mm), so this never touches the real one; the check refuses to run on a build that is not marked NocheDevBuild.
    /// M1.10 replaces this prompt with Noche's own UI.
    func pwOn() async {
        guard (Bundle.main.object(forInfoDictionaryKey: "NocheDevBuild") as? Bool) == true else { return finish(false, "this build is not marked NocheDevBuild: its keychain would be the real one") }
        guard await ready(), let win, let tab = win.activeTab else { return }
        func loadLogin() async -> Bool {
            let before = loads
            tab.loadURL(fixture("login.html"))
            return await until(15, { loads > before })
        }
        guard await loadLogin() else { return finish(false, "login.html never loaded") }
        let empty = await evaluate(tab, "document.getElementById('u').value + '|' + document.getElementById('p').matches(':-webkit-autofill')")
        let submitted = loads
        _ = await evaluate(tab, "document.getElementById('u').value = 'noche-user'; document.getElementById('p').value = 'noche-pass'; document.getElementById('f').requestSubmit(); 1")
        guard await until(15, { loads > submitted && passwordBubble() != nil }), let bubble = passwordBubble() else {
            return finish(false, "no save prompt after the form submission (windows: \(windowSummary()))")
        }
        let hidden = bubble.alphaValue == 0 && !bubble.isKeyWindow
        // NOCHE_TEST_PW_NOSAVE (negative control): the prompt is declined, so nothing is saved.
        let button = ProcessInfo.processInfo.environment["NOCHE_TEST_PW_NOSAVE"] == "1" ? "No Thanks" : "Save"
        // Chromium's dialogs ignore clicks for a moment after they appear (input protection): press again until the prompt goes.
        var gone = false
        for _ in 0..<20 where !gone {
            guard let w = passwordBubble() else { break }
            guard let press = axFind(w, role: "AXButton", title: button), press.accessibilityPerformPress() else {
                return finish(false, "the prompt has no \(button) button to press")
            }
            gone = await until(0.6, { passwordBubble() == nil })
        }
        guard passwordBubble() == nil else { return finish(false, "the prompt stayed after \(button)") }
        guard await loadLogin() else { return finish(false, "login.html did not load again") }
        var filled: String?
        for _ in 0..<100 {
            filled = await evaluate(tab, "document.getElementById('u').value + '|' + document.getElementById('p').matches(':-webkit-autofill')")
            if filled == "\"noche-user|true\"" { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        finish(hidden && empty == "\"|false\"" && filled == "\"noche-user|true\"" && violations.isEmpty,
               "Chromium's save prompt appeared hidden (alpha \(bubble.alphaValue), key \(bubble.isKeyWindow)), \(button) pressed, the next visit fills the saved credential (first visit \(empty ?? "nil"), second visit \(filled ?? "nil")) \(violations)")
    }
}
#endif
