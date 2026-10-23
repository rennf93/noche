chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  if (msg && msg.what === "tabs") {
    chrome.tabs.query({}).then((tabs) => reply({ count: tabs.length, urls: tabs.map((t) => t.url), sender: sender.tab && sender.tab.url }));
    return true;
  }
});
