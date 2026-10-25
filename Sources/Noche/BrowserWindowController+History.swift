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
        let typed = typedLoads.remove(tab.identifier) != nil
        guard (200..<400).contains(status), isWeb(tab.url), let store = app.writer?.store else { return }
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_RECORD"] == "1" { return }  // negative control: nothing is recorded
#endif
        do { try store.recordVisit(url: tab.url, title: tab.title, typed: typed, at: Date()) } catch {
            FileHandle.standardError.write(Data("NOCHE store record visit failed: \(error)\n".utf8))
        }
        recordedTitle[tab.identifier] = "\(tab.url)\n\(tab.title)"
    }

    /// The page's title often arrives after its load ends; each (address, title) pair is written once.
    func recordTitle(_ tab: NCTab) {
        guard !tab.title.isEmpty, isWeb(tab.url), let store = app.writer?.store else { return }
        let key = "\(tab.url)\n\(tab.title)"
        guard recordedTitle[tab.identifier] != key else { return }
        recordedTitle[tab.identifier] = key
#if NOCHE_TESTHOOKS
        if ProcessInfo.processInfo.environment["NOCHE_TEST_NO_RECORD"] == "1" { return }
#endif
        do { try store.updateTitle(url: tab.url, title: tab.title) } catch {
            FileHandle.standardError.write(Data("NOCHE store update title failed: \(error)\n".utf8))
        }
    }
}
