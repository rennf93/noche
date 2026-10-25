// Engine probe checks for the M1.4 / M1.5 browser surfaces research (risks R1, R2, R6, R7, R12, R13, R14). Needs the tab API
// (NOCHE_TABS_API). Hidden rule as everywhere: nothing here shows, activates or makes key any window.
#pragma once
#import <AppKit/AppKit.h>
#include <functional>
#include "include/cef_browser.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_permission_handler.h"
#include "include/views/cef_browser_view.h"

struct SurfHost {
  std::function<void(bool, NSString*)> finish;
  std::function<void(NSDictionary*, std::function<void(NSDictionary*)>)> extCmd;
  std::function<CefRefPtr<CefBrowserView>()> view;
  std::function<CefRefPtr<CefBrowser>()> first;  // the first tab (carries the content script)
  std::function<void(CefRefPtr<CefBrowser>, NSString*, bool, std::function<void(NSString*)>)> eval;  // Runtime.evaluate on a tab
  std::function<void(CefRefPtr<CefBrowser>, NSString*, NSDictionary*, std::function<void(NSDictionary*)>)> cdp;
  std::function<int()> windowCount;      // CGWindowList windows of this PID on layer 0
  std::function<int()> guardCalls;       // alpha guard hooked calls so far
  std::function<int()> activateBlocked;  // activation calls turned into no-ops so far
  std::function<NSString*()> url;        // the served page
  std::function<NSString*()> fallback;   // the first tab client: OnAfterCreated count, last id, ids that reached OnBeforeClose
  std::function<bool()> done;
};

// Before the engine starts: enables the handlers the check needs (they answer NULL otherwise).
void SurfEarly(NSString* check);
// Handlers for the first tab's client (the fallback client of every AddTab tab).
CefRefPtr<CefContextMenuHandler> SurfContextMenuHandler();
CefRefPtr<CefDownloadHandler> SurfDownloadHandler();
CefRefPtr<CefPermissionHandler> SurfPermissionHandler();
void SurfOnLoadEnd(int browserId, int status);
// True if |check| is one of the surfaces checks (it then owns the run and ends it through host.finish).
bool RunSurfacesCheck(NSString* check, const SurfHost& host);
