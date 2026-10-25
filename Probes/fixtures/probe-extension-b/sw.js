// Second fixture: what chrome.tabs / chrome.windows see, a badge, and uninstallSelf (the reply is sent first: the worker dies with the extension).
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg && msg.what === "tabsinfo") {
    chrome.tabs.query({}).then((all) => reply({ tabs: all.map((t) => ({ id: t.id, url: t.url || t.pendingUrl })) }), (e) => reply({ error: String(e) }));
    return true;
  }
  if (msg && msg.what === "windowNormal") {
    Promise.all([chrome.windows.getAll({ windowTypes: ["normal"], populate: true })]).then(([normal]) =>
      reply({ wins: normal.map((w) => ({ id: w.id, type: w.type, tabs: w.tabs ? w.tabs.length : -1 })) }), (e) => reply({ error: String(e) }));
    return true;
  }
  if (msg && msg.what === "badge") {
    Promise.all([chrome.action.setBadgeText({ text: msg.text }), chrome.action.setBadgeBackgroundColor({ color: msg.color })]).then(() => reply({ ok: true }), (e) => reply({ error: String(e) }));
    return true;
  }
  if (msg && msg.what === "uninstallSelf") {
    reply({ ok: true });
    setTimeout(() => chrome.management.uninstallSelf({ showConfirmDialog: false }).catch((e) => console.log("NOCHE-SW-B uninstallSelf rejected " + String(e))), 50);
    return;
  }
});
