// Pass rule of the install-no-window check (task B4), kept free of AppKit so a unit harness can replay recorded runs
// (Probes/store-rule-test, scripts/test-store-rule.sh). Narrowest correct rule: the stray window P3 removes is a
// Chrome browser window, class BrowserNativeWidgetWindow. The probe's own window is a CefNSWindow, the install sheet and
// the post-install dialog are NativeWidgetMacNSWindow, so counting that one class cannot be satisfied by a stock engine
// (the stock run showed one 1200x1396 BrowserNativeWidgetWindow and two activation attempts).
#pragma once
#include <string>

struct InstallFacts {
  int browserWindowsBefore = 0;  // NSApp.windows of class BrowserNativeWidgetWindow before the click
  int browserWindowsAfter = 0;   // ... after the install and the post-install wait
  int browserWindowOrders = 0;   // guard hits (order-in or makeKey) on that class during the whole run
  int staleTabTargets = 0;       // CDP targets at chrome://newtab, chrome://new-tab-page or chrome://apps; -1 if Target.getTargets failed
  bool dialogSeen = false;       // a new NativeWidgetMacNSWindow (the post-install dialog) appeared after the install sheet closed
  bool sameTabs = true;          // CefBrowserView tab count unchanged
};

inline bool InstallNoWindowOk(const InstallFacts& f, std::string* why) {
  std::string w;
  if (f.browserWindowsBefore != 0 || f.browserWindowsAfter != 0)
    w += "browser-window before=" + std::to_string(f.browserWindowsBefore) + " after=" + std::to_string(f.browserWindowsAfter) + " (want 0 and 0); ";
  if (f.browserWindowOrders != 0) w += "guard saw " + std::to_string(f.browserWindowOrders) + " order-in/makeKey on a browser window (want 0); ";
  if (f.staleTabTargets > 0) w += "new-tab/apps targets=" + std::to_string(f.staleTabTargets) + " (want 0); ";
  if (!f.dialogSeen) w += "post-install dialog window never appeared (UI path skipped); ";
  if (!f.sameTabs) w += "tab count changed; ";
  if (why) *why = w;
  return w.empty();
}
