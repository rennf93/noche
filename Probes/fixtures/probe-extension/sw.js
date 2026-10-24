// Answers {what:"tabs"} with what chrome.tabs sees, runs the probe commands create/activate, and keeps the tabId the popup resolved.
let popupTab = null;
console.log("NOCHE-SW loaded v1.2");
self.addEventListener("unhandledrejection", (e) => console.log("NOCHE-SW unhandledrejection", String(e.reason)));
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  console.log("NOCHE-SW msg", JSON.stringify(msg));
  if (msg && msg.what === "tabs") {
    Promise.all([chrome.tabs.query({}), chrome.tabs.query({ active: true })]).then(([all, act]) =>
      reply({ sw: "1.2", count: all.length, ids: all.map((t) => t.id), activeId: act.length ? act[0].id : null }));
    return true;
  }
  if (msg && msg.what === "create") {
    try {
      console.log("NOCHE-SW calling tabs.create");
      chrome.tabs.create({ url: msg.url }).then((t) => reply({ id: t.id, windowId: t.windowId, index: t.index }), (e) => reply({ error: "create rejected: " + ((e && e.message) || String(e)) }));
    } catch (e) { reply({ error: "create threw: " + ((e && e.message) || String(e)) }); }
    return true;
  }
  if (msg && msg.what === "activate") {  // makes the n-th tab (1-based, tab strip order) active
    chrome.tabs.query({}).then((all) => {
      all.sort((a, b) => a.index - b.index);
      const t = all[msg.n - 1];
      if (!t) { reply({ error: "no tab " + msg.n }); return; }
      return chrome.tabs.update(t.id, { active: true }).then((u) => reply({ id: u.id, index: u.index, active: u.active }));
    }).catch((e) => reply({ error: "activate rejected: " + ((e && e.message) || String(e)) }));
    return true;
  }
  if (msg && msg.what === "popup") { popupTab = msg.tabId; reply({ ok: true }); return; }
  if (msg && msg.what === "popupTab") { reply({ tabId: popupTab }); return; }
});
