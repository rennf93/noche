// Second fixture (profile-ext): own marker and own command channel, so it can be told apart from the first fixture on the same page.
document.documentElement.dataset.nocheExtB = "1";
document.addEventListener("noche-cmd-b", (e) => {
  chrome.runtime.sendMessage(JSON.parse(e.detail), (r) => {
    document.documentElement.dataset.nocheReplyB = JSON.stringify(r || { error: (chrome.runtime.lastError && chrome.runtime.lastError.message) || "no reply" });
  });
});
