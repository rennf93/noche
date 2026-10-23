// Answers {what:"tabs"} with what chrome.tabs sees, runs the probe commands create/activate, and keeps the tabId the popup resolved.
let popupTab = null;
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg && msg.what === "tabs") {
    Promise.all([chrome.tabs.query({}), chrome.tabs.query({ active: true })]).then(([all, act]) =>
      reply({ count: all.length, ids: all.map((t) => t.id), activeId: act.length ? act[0].id : null }));
    return true;
  }
  if (msg && msg.what === "create") {
    chrome.tabs.create({ url: msg.url }).then((t) => reply({ id: t.id, windowId: t.windowId, index: t.index }), (e) => reply({ error: String(e) }));
    return true;
  }
  if (msg && msg.what === "activate") {  // makes the n-th tab (1-based, tab strip order) active
    chrome.tabs.query({}).then((all) => {
      all.sort((a, b) => a.index - b.index);
      const t = all[msg.n - 1];
      if (!t) { reply({ error: "no tab " + msg.n }); return; }
      return chrome.tabs.update(t.id, { active: true }).then((u) => reply({ id: u.id, index: u.index, active: u.active }));
    }).catch((e) => reply({ error: String(e) }));
    return true;
  }
  if (msg && msg.what === "popup") { popupTab = msg.tabId; reply({ ok: true }); return; }
  if (msg && msg.what === "popupTab") { reply({ tabId: popupTab }); return; }
});
