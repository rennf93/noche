// Answers {what:"tabs"} with what chrome.tabs sees, and keeps the tabId the popup resolved.
let popupTab = null;
chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg && msg.what === "tabs") {
    Promise.all([chrome.tabs.query({}), chrome.tabs.query({ active: true })]).then(([all, act]) =>
      reply({ count: all.length, ids: all.map((t) => t.id), activeId: act.length ? act[0].id : null }));
    return true;
  }
  if (msg && msg.what === "popup") { popupTab = msg.tabId; reply({ ok: true }); return; }
  if (msg && msg.what === "popupTab") { reply({ tabId: popupTab }); return; }
});
