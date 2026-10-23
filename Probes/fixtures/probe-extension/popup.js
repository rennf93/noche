// Reports the tab this popup resolves as current back to the service worker.
chrome.tabs.query({ active: true, currentWindow: true }).then((tabs) => {
  chrome.runtime.sendMessage({ what: "popup", tabId: tabs.length ? tabs[0].id : null });
});
