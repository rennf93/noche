import AppKit
import CefBridge
import NocheCore
import NocheStore

/// Visit recording: an http or https main-frame load that ends with status 200 to 399 is a visit; the title follows later updates.
extension BrowserWindowController {
    func isWeb(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func recordVisit(_ tab: NCTab, status: Int) {
        let typed = typedLoads.removeValue(forKey: tab.identifier) != nil
        guard (200..<400).contains(status), isWeb(tab.url), let store = app.writer?.store else { return }
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_RECORD"] == "1" { return }  // negative control: nothing is recorded
#endif
        do { try store.recordVisit(url: tab.url, title: tab.title, typed: typed, at: Date()) } catch {
            FileHandle.standardError.write(Data("NOCHE store record visit failed: \(error)\n".utf8))
        }
        recordedTitle[tab.identifier] = "\(tab.url)\n\(tab.title)"
    }

#if NOCHE_TESTHOOKS
    static var titleWrites = 0
#endif
    /// Minimum seconds between title writes of one tab (ruling M38).
    static let titleInterval: TimeInterval = 2

    /// The page's title often arrives after its load ends; each (address, title) pair is written once, and a tab writes at most once per `titleInterval`:
    /// a title that changes sooner waits for the interval to end and then writes the tab's title as it is then.
    func recordTitle(_ tab: NCTab) {
        guard !tab.title.isEmpty, isWeb(tab.url), recordedTitle[tab.identifier] != "\(tab.url)\n\(tab.title)" else { return }
        switch titleThrottle.offer(tab.identifier, now: Date()) {
        case .writeNow: writeTitle(tab)
        case .pending: break
        case .later(let at):
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow)) { [weak self, weak tab] in
                MainActor.assumeIsolated {
                    guard let self, let tab, self.ids[tab.identifier] != nil else { return }  // the tab closed meanwhile
                    self.titleThrottle.flushed(tab.identifier, now: Date())
                    self.writeTitle(tab)
                }
            }
        }
    }

    private func writeTitle(_ tab: NCTab) {
        guard !tab.title.isEmpty, isWeb(tab.url), let store = app.writer?.store else { return }
        let key = "\(tab.url)\n\(tab.title)"
        guard recordedTitle[tab.identifier] != key else { return }
        recordedTitle[tab.identifier] = key
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_RECORD"] == "1" { return }
        Self.titleWrites += 1
#endif
        do { try store.updateTitle(url: tab.url, title: tab.title) } catch {
            FileHandle.standardError.write(Data("NOCHE store update title failed: \(error)\n".utf8))
        }
    }
}
