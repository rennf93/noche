#if NOCHE_TESTHOOKS
import AppKit
import CefBridge
import CryptoKit

/// Checks of M1.5 Task 3: the Downloads window and the sidebar button. Every download goes to a folder inside the self-test profile (AppDelegate
/// sets it at startup, before any download), from a local server; Open and Show in Finder are recorded by `DownloadsController.workspaceLog`.
extension SelfTest {
    static let slowSize = 4_000_000

    var dc: DownloadsController { app.downloads }

    /// The folder the app sends test downloads to (inside the wiped `Noche Test` profile).
    static var downloadFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Noche Test/Downloads", isDirectory: true) }

    func folderFiles() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: Self.downloadFolder.path))?.sorted() ?? [] }

    /// SHA-256 of a file, streamed with CryptoKit.
    func sha256(_ path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        var hash = SHA256()
        while let d = try? h.read(upToCount: 1 << 20), !d.isEmpty { hash.update(data: d) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The same digest from the system's own `shasum` tool: a second implementation next to CryptoKit and the server's hashlib.
    func shasum(_ path: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        p.arguments = ["-a", "256", path]
        p.standardOutput = out
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.split(separator: " ").first.map(String.init)
    }

    func item(_ id: UInt32) -> NCDownloadItem? { dc.items.first { $0.identifier == id } }

    /// Downloads (any state) with this display name.
    func downloads(named name: String) -> [NCDownloadItem] { dc.items.filter { $0.suggestedName == name } }

    /// Starts a slow download in |tab| and waits until it is running with some bytes; nil (after finishing the check) when it never did.
    func startSlow(_ tab: NCTab, server: SlowServer, minBytes: Int64 = 1, path: String = "slow.bin") async -> NCDownloadItem? {
        let before = Set(dc.items.map(\.identifier))
        tab.loadURL("http://127.0.0.1:\(server.port)/\(path)")
        guard await until(15, { dc.items.contains { !before.contains($0.identifier) && $0.state == .inProgress && $0.receivedBytes >= minBytes } }),
              let it = dc.items.first(where: { !before.contains($0.identifier) }) else {
            finish(false, "the slow download never reached \(minBytes) bytes (items: \(dc.items.map { "\($0.suggestedName):\($0.state.rawValue):\($0.receivedBytes)" }))")
            return nil
        }
        return it
    }

    func dlList() async {
        guard await ready(), let win, let tab = win.activeTab else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let homeBefore = listing(home)
        DownloadsController.workspaceLog = []
        let source = fixture("download.bin")
        for n in 1...2 {
            tab.loadURL(source)
            guard await until(20, { dc.items.filter { $0.state == .complete }.count == n }) else { return finish(false, "download \(n) of download.bin never completed (items \(dc.items.map { "\($0.suggestedName):\($0.state.rawValue)" }))") }
        }
        // Window > Downloads through the menu action: the native window, not a Chromium page.
        let tabsBefore = win.tabs.count
        app.showDownloads(nil)
        guard await until(5, { dc.windowController.window.isVisible }) else { return finish(false, "Window > Downloads did not show the Downloads window") }
        // Hidden runs: the Downloads window is held to the same terms as a browser window (`hidden` check): alpha 0, not key, floating, mouse ignored, the app not
        // active. The guards are the swizzles in NCWindow.mm (`installHiddenGuards`: GuardWindow zeroes alpha and ignores the mouse on every order-in, and
        // swz_makeKeyAndOrderFront orders the window in without making it key), installed by AppDelegate for every self-test.
        let shown = dc.windowController.window
        try? await Task.sleep(for: .milliseconds(300))
        func serverAlpha(_ w: NSWindow?) -> Double? {
            (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]])?.first { ($0[kCGWindowNumber as String] as? Int) == w?.windowNumber }?[kCGWindowAlpha as String] as? Double
        }
        let hiddenTerms = "alpha \(shown.alphaValue), key \(shown.isKeyWindow), level \(shown.level.rawValue), mouse ignored \(shown.ignoresMouseEvents), app active \(NSApp.isActive), window server alpha \(String(describing: serverAlpha(shown))) (browser window \(String(describing: serverAlpha(win.nsWindow))))"
        guard shown.alphaValue == 0, !shown.isKeyWindow, shown.level == .floating, shown.ignoresMouseEvents, !NSApp.isActive else {
            return finish(false, "the Downloads window can show: \(hiddenTerms)")
        }
        let rows = dc.windowController.rows
        guard rows.count == 2, win.tabs.count == tabsBefore else { return finish(false, "\(rows.count) rows (want 2), tabs \(tabsBefore) -> \(win.tabs.count)") }
        let names = rows.map(\.nameField.stringValue), details = rows.map(\.detailField.stringValue)
        // The second copy of the same file takes Chromium's " (1)" suffix (the bridge leaves the name to the target determiner), newest first.
        guard names == ["download (1).bin", "download.bin"] else { return finish(false, "row names \(names), want newest first with the (1) suffix") }
        guard details.allSatisfy({ $0 == "Complete - 524 KB" }), rows.allSatisfy({ $0.visibleButtons == ["Open", "Show in Finder", "Remove"] && $0.progress.isHidden }) else {
            return finish(false, "complete rows: details \(details), buttons \(rows.map(\.visibleButtons))")
        }
        let paths = dc.items.map(\.fullPath)  // newest first, like the rows
        rows[0].button("Open")?.performClick(nil)
        rows[1].button("Show in Finder")?.performClick(nil)
        let log = DownloadsController.workspaceLog.map { "\($0.call) \($0.path)" }
        guard log == ["open \(paths[0])", "reveal \(paths[1])"], paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            return finish(false, "NSWorkspace calls \(log), want open \(paths[0]) and reveal \(paths[1])")
        }
        // A third, running download shows size, percent and a progress bar, and sits on top.
        guard let server = await startSlowServer(size: Self.slowSize) else { return finish(false, "the slow download server did not start") }
        defer { server.stop() }
        guard let running = await startSlow(tab, server: server, minBytes: 200_000) else { return }
        guard await until(5, { dc.windowController.rows.count == 3 }) else { return finish(false, "no third row for the running download") }
        let top = dc.windowController.rows[0]
        let live = item(running.identifier)!
        let ok = top.nameField.stringValue == "slow.bin" && top.detailField.stringValue.contains(" of 4 MB (") && live.percent > 0 && live.percent < 100
            && !top.progress.isHidden && top.progress.doubleValue > 0 && top.progress.doubleValue < 100 && top.visibleButtons == ["Pause", "Cancel"]
            && dc.windowController.rows[1].nameField.stringValue == "download (1).bin"
        let detail = "running row: \(top.nameField.stringValue) \(top.detailField.stringValue), bar \(top.progress.doubleValue), buttons \(top.visibleButtons)"
        guard ok else { return finish(false, detail) }
        top.button("Cancel")?.performClick(nil)
        guard await until(10, { item(running.identifier)?.state == .canceled }) else { return finish(false, "Cancel did not end canceled") }
        try? await Task.sleep(for: .milliseconds(300))
        finish(listing(home) == homeBefore && violations.isEmpty,
               "the window is hidden (\(hiddenTerms)), two downloads of download.bin listed newest first as \(names) with \(details[0]), Open and Show in Finder reached NSWorkspace (\(log)), a running download showed \(detail), ~/Downloads untouched \(violations)")
    }

    func dlControls() async {
        guard await ready(), let win, let tab = win.activeTab, let server = await startSlowServer(size: Self.slowSize) else { return }
        defer { server.stop() }
        guard let started = await startSlow(tab, server: server) else { return }
        let id = started.identifier
        tab.close()
        guard await until(15, { app.controllers.isEmpty }) else { return finish(false, "the window did not close with its last tab") }
        app.showDownloads(nil)  // every tab (and window) is closed: the Downloads window is all that is left
        guard await until(5, { dc.windowController.window.isVisible && dc.windowController.rows.count == 1 }) else { return finish(false, "no Downloads window with one row after the tab closed") }
        let row = dc.windowController.rows[0]
        func state() -> NCDownloadState? { item(id)?.state }
        row.button("Pause")?.performClick(nil)
        guard await until(10, { state() == .paused }) else { return finish(false, "Pause left the download \(state()?.rawValue ?? -1)") }
        guard await until(3, { dc.windowController.rows[0].visibleButtons == ["Resume", "Cancel"] }) else { return finish(false, "paused row buttons \(dc.windowController.rows[0].visibleButtons)") }
        let frozen = item(id)!.receivedBytes
        try? await Task.sleep(for: .seconds(1.2))
        guard state() == .paused, item(id)!.receivedBytes - frozen <= 262_144 else { return finish(false, "a paused download kept growing (\(frozen) to \(item(id)!.receivedBytes))") }
        dc.windowController.rows[0].button("Resume")?.performClick(nil)
        guard await until(15, { state() == .inProgress && item(id)!.receivedBytes > frozen + 262_144 }) else { return finish(false, "Resume did not continue the download (state \(state()?.rawValue ?? -1), \(item(id)!.receivedBytes) of \(frozen))") }
        let partial = folderFiles()
        guard partial.count == 1, partial[0].hasSuffix(".crdownload") else { return finish(false, "while downloading the folder holds \(partial), want one .crdownload partial") }
        dc.windowController.rows[0].button("Cancel")?.performClick(nil)
        guard await until(10, { state() == .canceled }) else { return finish(false, "Cancel left the download \(state()?.rawValue ?? -1)") }
        guard await until(10, { folderFiles().isEmpty }) else { return finish(false, "Cancel left \(folderFiles()) in the folder") }
        let buttons = dc.windowController.rows[0].visibleButtons
        finish(buttons == ["Remove"] && app.controllers.isEmpty && violations.isEmpty,
               "with every tab closed: Pause froze the download at \(frozen) bytes, Resume continued it, Cancel removed the partial \(partial[0]) (folder empty), canceled row buttons (only Remove) \(buttons) \(violations)")
    }

    func dlTabClose() async {
        guard await ready(), let win, let server = await startSlowServer(size: Self.slowSize) else { return }
        defer { server.stop() }
        guard await openTabs(2), win.tabs.count == 2 else { return finish(false, "no second tab") }
        guard let tab = win.tabs.last, let started = await startSlow(tab, server: server, minBytes: 100_000) else { return }
        let id = started.identifier
        let atClose = item(id)!.receivedBytes
        tab.close()
        guard await until(10, { win.tabs.count == 1 }) else { return finish(false, "the download's tab did not close (\(win.tabs.count) tabs)") }
        guard await until(30, { item(id)?.state == .complete }), let done = item(id) else { return finish(false, "after its tab closed the download ended \(item(id)?.state.rawValue ?? -1) at \(item(id)?.receivedBytes ?? 0) bytes") }
        let crypto = sha256(done.fullPath), tool = shasum(done.fullPath)
        let size = (try? FileManager.default.attributesOfItem(atPath: done.fullPath)[.size] as? Int) ?? -1
        finish(done.receivedBytes > atClose && size == Self.slowSize && crypto == server.sha && tool == server.sha && violations.isEmpty,
               "started in a tab, closed it at \(atClose) bytes, the download completed (\(done.receivedBytes) bytes, file \(size)), SHA-256 \(crypto ?? "nil") equals the server's \(server.sha) (shasum \(tool ?? "nil")) \(violations)")
    }

    /// Phase 1 prints its verdict from `beforeExit` (the quit path's pause has to have landed); phase 2 resumes after the relaunch.
    /// |cancelRestored|: dl-restored-cancel-relaunch, the same first phase; phase 2 cancels the restored paused row and the engine's canceled update ends it
    /// (partial file deleted); |silent|: dl-restored-silent-relaunch, the same with Cancel never reaching the engine (an engine without patch 0011), so the
    /// give-up ends the row and the partial file stays.
    func dlQuitRelaunch(cancelRestored: Bool = false, silent: Bool = false) async {
        let state = SelfTest.downloadFolder.deletingLastPathComponent().appendingPathComponent("dl-relaunch.txt")
        let serverLog = SelfTest.downloadFolder.deletingLastPathComponent().appendingPathComponent("dl-server.log").path
        if phase == 1 {
            guard await ready(), let tab = win?.activeTab, let server = await startSlowServer(size: Self.slowSize, log: serverLog) else { return }
            slowServer = server
            guard let started = await startSlow(tab, server: server, minBytes: 800_000, path: "") else { return }  // a bare host address: the restored row is named after the host
            relaunchID = started.identifier
            try? "\(server.port) \(server.sha)".write(to: state, atomically: true, encoding: .utf8)
            app.selfTestFinished(ok: true)  // the quit itself: beforeExit judges what it did to the download
            return
        }
        let givenUp = SelfTest.downloadFolder.deletingLastPathComponent().appendingPathComponent("dl-given-up.txt")
        if cancelRestored && phase == 3 {
            // Third launch: the engine announces the restored item again, and its row stays hidden (the person removed it).
            guard let id = (try? String(contentsOf: givenUp, encoding: .utf8)).flatMap({ UInt32($0) }) else { return finish(false, "phase 2 left no given-up id") }
            guard await ready() else { return }
            guard await until(20, { NCDownloads.shared.items.contains { $0.identifier == id } }) else { return finish(false, "the engine did not announce item \(id) again, so nothing proves its row stays hidden (announced \(NCDownloads.shared.items.map(\.identifier)))") }
            try? await Task.sleep(for: .milliseconds(500))
            app.showDownloads(nil)
            guard await until(5, { dc.windowController.window.isVisible }) else { return finish(false, "no Downloads window") }
            guard dc.items.isEmpty, dc.windowController.rows.isEmpty else { return finish(false, "the removed row came back after the relaunch: \(dc.items.map { "\($0.identifier):\($0.suggestedName):\($0.state.rawValue)" })") }
            let announced = NCDownloads.shared.items.first { $0.identifier == id }?.state
            let partial = folderFiles().filter { $0.hasSuffix(".crdownload") }
            if silent {  // the engine never canceled it: still paused in its history, partial on disk
                guard !partial.isEmpty else { return finish(false, "the partial file is gone (folder \(folderFiles())) though the engine was never asked to cancel") }
                return finish(violations.isEmpty, "after the relaunch the engine announced item \(id) again (state \(announced?.rawValue ?? -1)) and its row stays hidden; the partial file stays on disk as \(partial) \(violations)")
            }
            guard announced == .canceled else { return finish(false, "the relaunch announced the canceled item as state \(announced?.rawValue ?? -1), want canceled (a paused one would bring Resume back)") }
            guard partial.isEmpty else { return finish(false, "the canceled download's partial file is back: \(partial)") }
            return finish(violations.isEmpty, "after the relaunch the engine announced item \(id) as canceled and its removed row stays hidden, no Resume anywhere; no partial file \(violations)")
        }
        let saved = ((try? String(contentsOf: state, encoding: .utf8)) ?? "").split(separator: " ").map(String.init)
        guard saved.count >= 3, let port = Int(saved[0]), let before = Int64(saved[2]) else { return finish(false, "phase 1 left no state (\(saved))") }
        guard await ready(), await until(20, { dc.items.contains { $0.suggestedName == "127.0.0.1" } }), let restored = dc.items.first(where: { $0.suggestedName == "127.0.0.1" }) else {
            return finish(false, "the download did not come back after the relaunch (items \(dc.items.map { "\($0.suggestedName):\($0.state.rawValue):\($0.receivedBytes)/\($0.totalBytes) \($0.url) at \($0.fullPath)" }))")
        }
        guard restored.state == .paused, restored.receivedBytes > 0, restored.receivedBytes <= before else {
            return finish(false, "restored download is state \(restored.state.rawValue) with \(restored.receivedBytes) bytes (phase 1 had \(before) at exit), want paused")
        }
        if cancelRestored {
            app.showDownloads(nil)
            guard await until(5, { dc.windowController.rows.first?.visibleButtons == ["Resume", "Cancel"] }) else { return finish(false, "restored row buttons \(dc.windowController.rows.first?.visibleButtons ?? [])") }
            let partialBefore = folderFiles().filter { $0.hasSuffix(".crdownload") }
            guard !partialBefore.isEmpty else { return finish(false, "no partial file before Cancel (folder \(folderFiles())), so its absence after would prove nothing") }
            let id = restored.identifier
            dc.silentRestoredCancel = silent
            dc.canceledAt[id] = nil  // only an update after this Cancel counts
            let giveUpsBefore = DownloadsController.giveUps, t0 = Date()
            DownloadsController.cancelRequests = 0
            DownloadsController.engineCancels = 0
            dc.windowController.rows[0].button("Cancel")?.performClick(nil)
            if silent {
                // The engine never hears of it: the row stays paused through the grace and then the give-up takes it off the list.
                try? await Task.sleep(for: .seconds(DownloadsController.cancelGrace - 0.5))
                guard item(id)?.state == .paused, dc.canceledAt[id] == nil else { return finish(false, "the seam let the engine cancel it (state \(item(id)?.state.rawValue ?? -1))") }
                guard await until(DownloadsController.cancelGrace + 8, { item(id) == nil }) else {
                    return finish(false, "the restored paused row has no way out: after Cancel it is still state \(item(id)?.state.rawValue ?? -1) with buttons \(dc.windowController.rows.first?.visibleButtons ?? [])")
                }
                guard DownloadsController.giveUps == giveUpsBefore + 1, dc.windowController.rows.isEmpty else { return finish(false, "the row left but not by the give-up (give-ups \(DownloadsController.giveUps - giveUpsBefore)): \(rowNamesNow())") }
                let partial = folderFiles().filter { $0.hasSuffix(".crdownload") }
                guard !partial.isEmpty else { return finish(false, "the partial file is gone (folder \(folderFiles())) though the engine was never asked to cancel") }
                try? "\(id)".write(to: givenUp, atomically: true, encoding: .utf8)
                return finish(violations.isEmpty, "relaunched with the download paused at \(restored.receivedBytes) bytes: with the engine silent, Cancel on the restored row was given up after the grace (one give-up), the partial file stays \(partial) \(violations)")
            }
            // The engine's canceled update arrives well before the grace, and nothing else ended the row.
            guard await until(DownloadsController.cancelGrace - 0.5, { dc.canceledAt[id] != nil }), let at = dc.canceledAt[id] else {
                return finish(false, "the restored paused row has no way out: Cancel reached the controller \(DownloadsController.cancelRequests) times and the app asked the engine to cancel \(DownloadsController.engineCancels) times, and no canceled update came within \(DownloadsController.cancelGrace - 0.5) s of Cancel (state \(item(id)?.state.rawValue ?? -1), rows \(rowNamesNow()))")
            }
            guard at >= t0, at.timeIntervalSince(t0) < DownloadsController.cancelGrace else { return finish(false, "the canceled update came \(at.timeIntervalSince(t0)) s after Cancel") }
            guard await until(5, { folderFiles().filter { $0.hasSuffix(".crdownload") }.isEmpty }) else { return finish(false, "the engine canceled the item but the partial file is still on disk: \(folderFiles())") }
            try? await Task.sleep(for: .seconds(DownloadsController.cancelGrace + 0.5))  // past the give-up's deadline
            guard DownloadsController.giveUps == giveUpsBefore else { return finish(false, "the give-up fired though the engine canceled it") }
            guard item(id)?.state == .canceled, dc.windowController.rows.first?.visibleButtons == ["Remove"], dc.windowController.rows.first?.detailField.stringValue == "Canceled" else {
                return finish(false, "the canceled restored row reads \(dc.windowController.rows.first?.detailField.stringValue ?? "none") with buttons \(dc.windowController.rows.first?.visibleButtons ?? []), state \(item(id)?.state.rawValue ?? -1)")
            }
            dc.windowController.rows[0].button("Remove")?.performClick(nil)
            guard dc.windowController.rows.isEmpty, dc.items.isEmpty else { return finish(false, "the restored row is still listed: \(rowNamesNow())") }
            try? "\(id)".write(to: givenUp, atomically: true, encoding: .utf8)
            finish(violations.isEmpty, "relaunched with the download paused at \(restored.receivedBytes) bytes: Cancel on the restored row got the engine's canceled update \(Int(at.timeIntervalSince(t0) * 1000)) ms later, no give-up, a Canceled row with Remove, the partial file \(partialBefore) deleted \(violations)")
            return
        }
        guard let server = await startSlowServer(size: Self.slowSize, port: port, log: serverLog) else { return finish(false, "the slow server did not come back on port \(port)") }
        slowServer = server  // stopped by beforeExit on every way out
        guard server.sha == saved[1] else { return finish(false, "the slow server's content changed (SHA-256 \(server.sha), phase 1 had \(saved[1]))") }
        app.showDownloads(nil)
        guard await until(5, { dc.windowController.rows.first?.visibleButtons == ["Resume", "Cancel"] }) else { return finish(false, "restored row buttons \(dc.windowController.rows.first?.visibleButtons ?? [])") }
        dc.windowController.rows[0].button("Resume")?.performClick(nil)
        guard await until(30, { item(restored.identifier)?.state == .complete }), let done = item(restored.identifier) else {
            return finish(false, "Resume left the download \(item(restored.identifier)?.state.rawValue ?? -1) at \(item(restored.identifier)?.receivedBytes ?? 0) bytes")
        }
        let crypto = sha256(done.fullPath), tool = shasum(done.fullPath)
        let ranges = ((try? String(contentsOfFile: serverLog, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int($0.dropFirst("GET range=".count)) }
        let resumed = ranges.last.map { $0 > 0 && Int64($0) <= before } ?? false
        finish(crypto == server.sha && tool == server.sha && resumed && violations.isEmpty,
               "relaunched with the download paused at \(restored.receivedBytes) bytes, Resume asked the server for the rest (requests with range start \(ranges)), SHA-256 \(crypto ?? "nil") equals the server's \(server.sha) (shasum \(tool ?? "nil")) \(violations)")
    }

    private func rowNamesNow() -> [String] { dc.windowController.rows.map { $0.nameField.stringValue } }

    /// Phase 1's verdict, after the quit's pause: the download must be paused with bytes, and the state file gets the bytes at exit.
    func dlQuitVerdict() {
        defer { slowServer?.stop() }  // every way out, with or without a verdict
        guard check == "dl-quit-relaunch" || check == "dl-restored-cancel-relaunch" || check == "dl-restored-silent-relaunch" || check.hasPrefix("quit-gap-"), phase == 1, !verdictPrinted, let id = relaunchID else { return }
        let it = item(id)
        let ok = it?.state == .paused && (it?.receivedBytes ?? 0) >= 800_000
        let state = SelfTest.downloadFolder.deletingLastPathComponent().appendingPathComponent("dl-relaunch.txt")
        if let it, let old = try? String(contentsOf: state, encoding: .utf8) { try? "\(old) \(it.receivedBytes)".write(to: state, atomically: true, encoding: .utf8) }
        line(ok && violations.isEmpty ? "pass" : "fail", "download in progress at the quit, paused by it (state \(it?.state.rawValue ?? -1), \(it?.receivedBytes ?? 0) bytes, folder \(folderFiles())) \(violations)")
        if !(ok && violations.isEmpty) { app.exitCodeOverride = 1 }
    }

    func snapshot(_ v: NSView) -> NSBitmapImageRep? {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    /// Pixels with any alpha in a band around the ring's radius (view points), and the pixels that differ between two renderings.
    func ringPixels(_ rep: NSBitmapImageRep, in v: NSView) -> Int {
        let scale = CGFloat(rep.pixelsWide) / v.bounds.width, c = NSPoint(x: v.bounds.midX, y: v.bounds.midY), r = ChromeStyle.downloadRingRadius
        var n = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            let d = hypot((CGFloat(x) + 0.5) / scale - c.x, (CGFloat(y) + 0.5) / scale - c.y)
            if abs(d - r) <= 1.2, (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { n += 1 }
        } }
        return n
    }

    func dlRing() async {
        guard await ready(), let ctl, let win, let tab = win.activeTab, let server = await startSlowServer(size: Self.slowSize) else { return }
        defer { server.stop() }
        let button = ctl.sidebar.downloadButton
        guard let idleRep = snapshot(button), let box = ctl.frame(ofIdentifier: "sidebar.downloads"), box.minX < ChromeStyle.sidebarWidth / 2, box.maxY > win.nsWindow!.frame.height - 60 else {
            return finish(false, "no sidebar download button at the bottom left (\(String(describing: ctl.frame(ofIdentifier: "sidebar.downloads"))))")
        }
        let idle = ringPixels(idleRep, in: button)
        guard button.progress == nil, dc.ring == nil, idle == 0 else { return finish(false, "idle button has a ring (progress \(String(describing: button.progress)), ring pixels \(idle))") }
        guard let started = await startSlow(tab, server: server, minBytes: 200_000) else { return }
        guard await until(5, { button.progress != nil }), let first = button.progress, let rep = snapshot(button) else { return finish(false, "no ring on the button while a download runs (progress \(String(describing: button.progress)))") }
        let drawn = ringPixels(rep, in: button)
        guard drawn > 40, first > 0 else { return finish(false, "the ring drew \(drawn) pixels at \(first)") }
        guard await until(10, { (button.progress ?? 0) > first + 0.05 }) else { return finish(false, "the ring did not advance from \(first) (now \(String(describing: button.progress)))") }
        // A click on the button opens the Downloads window.
        BrowserWindowController.actionCounts = [:]
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: win.nsWindow?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        if let click { button.mouseUp(with: click) }
        guard BrowserWindowController.actionCounts["showDownloads"] == 1, await until(5, { dc.windowController.window.isVisible }) else { return finish(false, "a click on the button did not open the Downloads window") }
        NCDownloads.shared.cancel(started.identifier)
        guard await until(10, { button.progress == nil }), let after = snapshot(button) else { return finish(false, "the ring stayed after the download ended (progress \(String(describing: button.progress)))") }
        let gone = ringPixels(after, in: button)
        finish(gone == 0 && violations.isEmpty, "idle: no ring (\(idle) ring pixels), downloading: ring of \(drawn) pixels at \(Int(first * 100)) percent and advancing, bottom left at \(box), click opened the window, canceled: no ring (\(gone) pixels) \(violations)")
    }
}
#endif
