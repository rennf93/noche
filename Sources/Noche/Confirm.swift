import AppKit

/// The one place Noche asks a yes or no before something it cannot undo (Delete Group; Close All Tabs and the last-tab warning reuse it).
/// Checks never see a dialog: a hidden window is never key, so test builds answer through |answer| and keep every question in |asked|.
@MainActor
enum Confirm {
    struct Question: Equatable {
        let message: String
        let detail: String
        let button: String
    }

#if NOCHE_TESTHOOKS
    static var asked: [Question] = []
    /// What a test build answers (a check sets it to refuse).
    static var answer = true
#endif

    static func ask(_ q: Question) -> Bool {
#if NOCHE_TESTHOOKS
        asked.append(q)
        return answer
#else
        let alert = NSAlert()
        alert.messageText = q.message
        alert.informativeText = q.detail
        alert.addButton(withTitle: q.button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
#endif
    }
}
