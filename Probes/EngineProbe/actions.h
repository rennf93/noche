// Engine probe checks for extension toolbar actions and popups (task B5). Compiled with NOCHE_ACTIONS_API=1 against the
// engine that has CefBrowserView::GetExtensionActions; without it the checks fail with a clear message.
#pragma once
#import <AppKit/AppKit.h>
#include <functional>
#include "include/views/cef_browser_view.h"

// What the checks need from main.mm. No CefRefPtr is stored: view() hands a fresh reference each call.
struct ActionsHost {
  std::function<void(bool, NSString*)> finish;  // Finish(ok, detail)
  std::function<void(NSDictionary*, std::function<void(NSDictionary*)>)> extCmd;  // ExtCmd(cmd, cb)
  std::function<void(NSString*)> log;
  std::function<CefRefPtr<CefBrowserView>()> view;
  std::function<NSWindow*()> window;  // the probe's alpha-0 window
  std::function<bool()> done;         // g_done
  std::function<NSString*()> url;     // page URL for extra tabs
};

// Returns true if |check| is one of: actions-list badge-observer popup-anchor popup-tabid popup-closes (it then owns
// the run and ends it through host.finish), false for any other name.
bool RunActionsCheck(NSString* check, const ActionsHost& host);
