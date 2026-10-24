// Engine probe checks for the Chrome Web Store (task B4): store-stock, store-ua, store-brand, store-ua-brand (the U3/U4
// experiments) and install-no-window (P3). Hidden rule: the probe never shows or activates anything; the caller
// installs the activation guard (NSApplication activate calls become no-ops) and the sheet alpha guard first.
#pragma once
#import <AppKit/AppKit.h>
#include <functional>

struct StoreHost {
  std::function<void(bool, NSString*)> finish;
  std::function<void(NSString*, NSDictionary*, std::function<void(NSDictionary*)>)> send;  // CDP method, params, reply
  std::function<void(NSString*, bool, std::function<void(NSString*)>)> eval;                // expression, await, string value
  std::function<void(std::function<void(NSDictionary*)>)> setEventHook;                     // CDP events (no id)
  std::function<NSWindow*()> window;
  std::function<bool()> done;
  std::function<int()> tabCount;                                                            // -1 without the tab API
  std::function<void(std::function<void(bool)>)> ensureVisible;
  std::function<int()> activateBlocked;                                                     // blocked activate calls so far
  std::function<bool()> guardsInstalled;
  std::function<int()> browserWindowOrders;                                                 // guard hits on BrowserNativeWidgetWindow
};

// True if |check| is a store check (it then owns the run and ends it through host.finish).
bool RunStoreCheck(NSString* check, const StoreHost& host);
bool IsStoreCheck(NSString* check);
