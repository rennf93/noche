// Marks the page, then asks the service worker what chrome.tabs sees and writes it to the DOM.
document.documentElement.dataset.nocheExt = "1";
chrome.runtime.sendMessage({ what: "tabs" }, (r) => {
  document.documentElement.dataset.nocheTabs = JSON.stringify(r || { error: String(chrome.runtime.lastError) });
});
