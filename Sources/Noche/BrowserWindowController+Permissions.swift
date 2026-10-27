import AppKit
import CefBridge
import NocheCore
import NocheStore

/// A site permission request the engine waits for. |kinds| are the stored kinds (camera, microphone, geolocation, notifications) it names.
struct PermissionRequest {
    let tab: NCTab
    let id: UInt64
    let origin: String
    /// The origin of the tab's top-level page. A request from an iframe has an |origin| of its own, and then no Allow is ever stored or used.
    let topOrigin: String
    var embedded: Bool { origin != topOrigin }
    let mask: NCPermissionMask
    let kinds: [String]
    let decide: (Bool, Bool) -> Void
}

/// Site permissions (M1.5 Task 4): a stored Block or Allow answers a request without a card, anything else asks through the prompt card.
extension BrowserWindowController {
    static let namedMask: NCPermissionMask = [.camera, .microphone, .geolocation, .notifications]
    static let namedKinds: [(NCPermissionMask, String)] = [(.camera, "camera"), (.microphone, "microphone"), (.geolocation, "geolocation"), (.notifications, "notifications")]

    func window(_ window: NCWindow, tab: NCTab, requestsPermissions mask: NCPermissionMask, origin: String, topLevelOrigin: String, promptId: UInt64, decide: @escaping (Bool, Bool) -> Void) {
        let kinds = Self.namedKinds.filter { mask.contains($0.0) }.map(\.1)
#if NOCHE_TESTHOOKS
        // A test run never reaches a macOS permission dialog: only the perm-* checks see the card at all.
        if let test = app.selfTest {
            test.permissionRequests.append((mask, origin, topLevelOrigin, promptId))
            if !test.check.hasPrefix("perm-") { let a = test.permissionAnswer(mask); return decide(a.allow, a.remember) }
        }
#endif
        // Any stored Block wins; all stored Allow answers Allow (never for an iframe's request: the Allow was for the page the person was looking at); otherwise ask.
        // "Other" (a kind with no name here) is never stored.
        let embedded = origin != topLevelOrigin
        if let store = app.writer?.store, !kinds.isEmpty, !BarHook.on("PERM_NOLOOKUP") {  // negative control: the store is never asked
            let stored = kinds.map { try? store.permission(origin: origin, kind: $0) }
            if stored.contains(.block) { return decide(false, true) }
            // A bit Noche cannot name (Other, Screen) is never covered by a stored Allow: the card asks.
            if stored.allSatisfy({ $0 == .allow }), mask.subtracting(Self.namedMask).isEmpty, !embedded || BarHook.on("PERM_EMBEDALLOW") { return decide(true, false) }  // negative control: an iframe is answered from a stored Allow
        }
        permissionQueue.append(PermissionRequest(tab: tab, id: promptId, origin: origin, topOrigin: topLevelOrigin, mask: mask, kinds: kinds, decide: decide))
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
        // The whole mask counts, Screen and Other too; only the MIDI sysex check (no macOS dialog exists for it) opens Other for its one Allow.
        if allow, let test = app.selfTest, BarHook.on("PERM_GUARDKINDS") ? !r.kinds.isEmpty : !(r.mask == .other && test.allowOther) {  // negative control: named kinds only
            test.violations.append("allowed \(r.mask) in a test run"); allow = false; remember = false
        }
#endif
        remember = remember || (!allow && BarHook.on("PERM_DISMISSSTORES"))  // negative control: a dismiss stores a Block
        if remember, !(allow && r.embedded && !BarHook.on("PERM_EMBEDALLOW")), !BarHook.on("PERM_NOSTORE"), let store = app.writer?.store {
            for k in r.kinds { try? store.setPermission(origin: r.origin, kind: k, decision: allow ? .allow : .block) }
        }
        r.decide(allow && !BarHook.on("PERM_ALLOWDENY"), remember && !r.kinds.isEmpty)  // negative control: Allow tells the page no
        syncPermissionPrompt()
    }

    func syncPermissionPrompt() {
        guard installed else { return }
        guard let r = shownPermission, !BarHook.on("PERM_NOCARD") else { permissionPrompt.isHidden = true; return }  // negative control: the card never shows
        let site = r.embedded ? "\(Self.hostText(r.origin)) on \(Self.hostText(r.topOrigin))" : Self.hostText(r.origin)
        permissionPrompt.show(site: site, request: Self.requestText(r.mask), blocks: !r.kinds.isEmpty || BarHook.on("PERM_BLOCKLABEL"))  // negative control: Block on a request that is never remembered
    }

    /// The tab navigated or closed: its requests are over (the engine dismissed them; the bridge ignores a second answer).
    func dropPermissionRequests(of tab: NCTab) {
        let gone = permissionQueue.filter { $0.tab === tab }
        permissionQueue.removeAll { $0.tab === tab }
        for r in gone { r.decide(false, false) }
        syncPermissionPrompt()
    }

    static func hostText(_ origin: String) -> String {
        let url = URL(string: origin)
        return url?.host.map { h in url?.port.map { "\(h):\($0)" } ?? h } ?? origin
    }

    static func requestText(_ mask: NCPermissionMask) -> String {
        PermissionRequestText.text(camera: mask.contains(.camera), microphone: mask.contains(.microphone), geolocation: mask.contains(.geolocation),
                                   notifications: mask.contains(.notifications), screen: mask.contains(.screen))
    }

    /// The engine dismissed the request |id| that the host holds. (The request is found by its id: another request answered since would shift a position.)
    func window(_ window: NCWindow, tab: NCTab, dismissedPermissionPromptId id: UInt64) {
        let i = BarHook.on("PERM_DISMISSFIRST") ? permissionQueue.firstIndex { $0.tab === tab } : permissionQueue.firstIndex { $0.id == id && $0.tab === tab }  // negative control: the tab's first request goes
        guard let i else { return }
        permissionQueue.remove(at: i)
        syncPermissionPrompt()
    }

    /// Forgets a stored decision: the Noche row and the engine's own copy (M1.8's settings page calls this; nothing in the UI does yet).
    func forgetPermission(origin: String, kind: String) {
        try? app.writer?.store.removePermission(origin: origin, kind: kind)
        NCEngine.resetContentSetting(forOrigin: origin, kind: kind)
    }
}
