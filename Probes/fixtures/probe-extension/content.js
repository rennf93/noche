// Marks the page, then asks the service worker what chrome.tabs sees and writes it to the DOM.
document.documentElement.dataset.nocheExt = "1";
chrome.runtime.sendMessage({ what: "tabs" }, (r) => {
  document.documentElement.dataset.nocheTabs = JSON.stringify(r || { error: String(chrome.runtime.lastError) });
});

// Engine probe commands: the page (main world) dispatches 'noche-cmd' with a JSON string, the answer lands in dataset.nocheReply.
document.addEventListener("noche-cmd", (e) => {
  chrome.runtime.sendMessage(JSON.parse(e.detail), (r) => {
    document.documentElement.dataset.nocheReply = JSON.stringify(r || { error: String(chrome.runtime.lastError) });
  });
});
