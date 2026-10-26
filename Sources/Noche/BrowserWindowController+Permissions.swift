import AppKit
import CefBridge
import NocheCore
import NocheStore

/// A site permission request the engine waits for. |kinds| are the stored kinds (camera, microphone, geolocation, notifications) it names.
struct PermissionRequest {
    let tab: NCTab
    let origin: String
    let mask: NCPermissionMask
    let kinds: [String]
    let decide: (Bool, Bool) -> Void
}

/// Site permissions (M1.5 Task 4): a stored Block or Allow answers a request without a card, anything else asks through the prompt card.
extension BrowserWindowController {
    static let namedMask: NCPermissionMask = [.camera, .microphone, .geolocation, .notifications]
    static let namedKinds: [(NCPermissionMask, String)] = [(.camera, "camera"), (.microphone, "microphone"), (.geolocation, "geolocation"), (.notifications, "notifications")]

    func window(_ window: NCWindow, tab: NCTab, requestsPermissions mask: NCPermissionMask, origin: String, decide: @escaping (Bool, Bool) -> Void) {
        let kinds = Self.namedKinds.filter { mask.contains($0.0) }.map(\.1)
#if NOCHE_TESTHOOKS
        // A test run never reaches a macOS permission dialog: only the perm-* checks see the card at all.
        if let test = app.selfTest {
            test.permissionRequests.append((mask, origin))
            if !test.check.hasPrefix("perm-") { let a = test.permissionAnswer(mask); return decide(a.allow, a.remember) }
        }
#endif
        // Any stored Block wins; all stored Allow answers Allow; otherwise ask. "Other" (a kind with no name here) is never stored.
        if let store = app.writer?.store, !kinds.isEmpty, !BarHook.on("PERM_NOLOOKUP") {  // negative control: the store is never asked
            let stored = kinds.map { try? store.permission(origin: origin, kind: $0) }
            if stored.contains(.block) { return decide(false, true) }
            // A bit Noche cannot name (Other, Screen) is never covered by a stored Allow: the card asks.
            if stored.allSatisfy({ $0 == .allow }), mask.subtracting(Self.namedMask).isEmpty { return decide(true, false) }
        }
        permissionQueue.append(PermissionRequest(tab: tab, origin: origin, mask: mask, kinds: kinds, decide: decide))
        syncPermissionPrompt()
    }

    func setUpPermissionPrompt() {
        permissionPrompt.block.target = self
        permissionPrompt.block.action = #selector(permissionBlock)
        permissionPrompt.allow.target = self
        permissionPrompt.allow.action = #selector(permissionAllow)
        permissionPrompt.close.onClick = { [weak self] in self?.permissionAnswer(allow: false, remember: false) }
    }
    @objc private func permissionBlock() { permissionAnswer(allow: false, remember: true) }
    @objc private func permissionAllow() { permissionAnswer(allow: true, remember: true) }

    /// The request the card shows: the oldest of the active tab.
    var shownPermission: PermissionRequest? { permissionQueue.first { $0.tab === activeTab } }

    /// |remember| stores Block or Allow for each named kind (a request with no named kind is answered once); a dismiss answers once and stores nothing.
    func permissionAnswer(allow: Bool, remember: Bool) {
        guard let i = permissionQueue.firstIndex(where: { $0.tab === activeTab }) else { return }
        let r = permissionQueue.remove(at: i)
        var allow = allow, remember = remember
#if NOCHE_TESTHOOKS
        // The card never allows a named kind in a test run (a macOS camera, microphone, location or notification dialog could follow); this runs before the store write.
        if allow, !r.kinds.isEmpty { app.selfTest?.violations.append("allowed \(r.kinds) in a test run"); allow = false; remember = false }
#endif
        remember = remember || (!allow && BarHook.on("PERM_DISMISSSTORES"))  // negative control: a dismiss stores a Block
        if remember, !BarHook.on("PERM_NOSTORE"), let store = app.writer?.store {
            for k in r.kinds { try? store.setPermission(origin: r.origin, kind: k, decision: allow ? .allow : .block) }
        }
        r.decide(allow && !BarHook.on("PERM_ALLOWDENY"), remember && !r.kinds.isEmpty)  // negative control: Allow tells the page no
        syncPermissionPrompt()
    }

    func syncPermissionPrompt() {
        guard installed else { return }
        guard let r = shownPermission, !BarHook.on("PERM_NOCARD") else { permissionPrompt.isHidden = true; return }  // negative control: the card never shows
        let url = URL(string: r.origin)
        let host = url?.host.map { h in url?.port.map { "\(h):\($0)" } ?? h } ?? r.origin
        permissionPrompt.show(site: host, request: Self.requestText(r.mask))
    }

    /// The tab navigated or closed: its requests are over (the engine dismissed them; the bridge ignores a second answer).
    func dropPermissionRequests(of tab: NCTab) {
        let gone = permissionQueue.filter { $0.tab === tab }
        permissionQueue.removeAll { $0.tab === tab }
        for r in gone { r.decide(false, false) }
        syncPermissionPrompt()
    }

    static func requestText(_ mask: NCPermissionMask) -> String {
        PermissionRequestText.text(camera: mask.contains(.camera), microphone: mask.contains(.microphone), geolocation: mask.contains(.geolocation),
                                   notifications: mask.contains(.notifications), screen: mask.contains(.screen))
    }

    /// The engine dismissed the |index|th request of |tab| that the host holds.
    func permissionRequestDismissed(tab: NCTab, at index: Int) {
        let mine = permissionQueue.indices.filter { permissionQueue[$0].tab === tab }
        guard mine.indices.contains(index) else { return }
        permissionQueue.remove(at: mine[index])
        syncPermissionPrompt()
    }

    func window(_ window: NCWindow, tab: NCTab, dismissedPermissionRequestNumber index: Int) { permissionRequestDismissed(tab: tab, at: index) }

    /// Forgets a stored decision: the Noche row and the engine's own copy (M1.8's settings page calls this; nothing in the UI does yet).
    func forgetPermission(origin: String, kind: String) {
        try? app.writer?.store.removePermission(origin: origin, kind: kind)
        NCEngine.resetContentSetting(forOrigin: origin, kind: kind)
    }
}
