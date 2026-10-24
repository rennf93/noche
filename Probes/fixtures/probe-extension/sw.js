// Also sets the badge ("badge") and drives the action popup: the popup reports its tabId ("popup") and clicks ("popupClick"), "popupclick" clicks it over the debugger API.
// Answers {what:"tabs"} with what chrome.tabs sees, {what:"windowNormal"} with the window types and the normal filters, runs the probe commands create/activate, and keeps the tabId the popup resolved.
let popupTab = null, popupClicks = 0;
console.log("NOCHE-SW loaded v1.3");
self.addEventListener("unhandledrejection", (e) => console.log("NOCHE-SW unhandledrejection", String(e.reason)));
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  console.log("NOCHE-SW msg", JSON.stringify(msg));
  if (msg && msg.what === "tabs") {
    Promise.all([chrome.tabs.query({}), chrome.tabs.query({ active: true })]).then(([all, act]) =>
      reply({ sw: "1.3", count: all.length, ids: all.map((t) => t.id), activeId: act.length ? act[0].id : null }));
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
  if (msg && msg.what === "windowNormal") {  // what the extension sees as window type, and what the "normal" filters return
    Promise.all([chrome.windows.getAll({ populate: true }), chrome.windows.getAll({ windowTypes: ["normal"], populate: true }),
                 chrome.tabs.query({ windowType: "normal" }), chrome.tabs.query({})]).then(([all, normal, qNormal, qAll]) =>
      reply({ rawTypes: all.map((w) => w.type), wins: normal.map((w) => ({ id: w.id, type: w.type, tabs: w.tabs ? w.tabs.length : -1 })), qNormal: qNormal.length, qAll: qAll.length }),
      (e) => reply({ error: "windows rejected: " + ((e && e.message) || String(e)) }));
    return true;
  }
  if (msg && msg.what === "badge") {  // sets the badge for every tab: text and a #RRGGBB background
    Promise.all([chrome.action.setBadgeText({ text: msg.text }), chrome.action.setBadgeBackgroundColor({ color: msg.color })])
      .then(() => reply({ ok: true }), (e) => reply({ error: "badge rejected: " + ((e && e.message) || String(e)) }));
    return true;
  }
  if (msg && msg.what === "popup") { popupTab = msg.tabId; reply({ ok: true }); return; }
  if (msg && msg.what === "popupClick") { popupClicks++; reply({ ok: true }); return; }
  if (msg && msg.what === "popupTab") { reply({ tabId: popupTab, clicks: popupClicks }); return; }
  if (msg && msg.what === "popupclick") {  // a CDP mouse click on #b in the open popup
    chrome.debugger.getTargets().then((ts) => {
      const t = ts.find((x) => x.url && x.url.endsWith("/popup.html"));
      if (!t) { reply({ error: "no popup target among " + ts.map((x) => x.type + ":" + x.url).join(" ") }); return; }
      const target = { targetId: t.id };
      return chrome.debugger.attach(target, "1.3").then(async () => {
        for (const type of ["mousePressed", "mouseReleased"])
          await chrome.debugger.sendCommand(target, "Input.dispatchMouseEvent", { type, x: 40, y: 20, button: "left", clickCount: 1 });
        await chrome.debugger.detach(target);
        reply({ ok: true });
      });
    }).catch((e) => reply({ error: "popupclick failed: " + ((e && e.message) || String(e)) }));
    return true;
  }
});
