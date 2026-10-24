// Engine probe: one check per launch (--probe=<check>), result as "PROBE <check> pass|fail <detail>" on stdout.
// Driven by scripts/probe-engine.sh. Chrome-style window and CDP plumbing are copied from Spikes/ChromeStyle.
#import <AppKit/AppKit.h>
#import "CefBridge.h"
#include <algorithm>
#include <chrono>
#include <functional>
#include <memory>
#include <map>
#include <set>
#include <string>
#include <vector>
#include <signal.h>
#include <unistd.h>
#include <crt_externs.h>
#include <execinfo.h>
#include <sys/ucontext.h>
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_trace.h"
#include "include/cef_request_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"
#include "actions.h"
#include "store.h"

static NSString* g_check = nil;
static NSString* g_logPath = nil;
static CefRefPtr<CefWindow> g_window;
static CefRefPtr<CefBrowserView> g_view;
static CefRefPtr<CefBrowser> g_browser;  // the first tab: it carries the extension's content script
static NSString* g_url = @"about:blank";
static int g_created = 0;  // browsers the window's views reported
static int g_tab_added = 0, g_active_changed = 0;  // CefBrowserViewDelegate tab callbacks seen
static std::set<int> g_before_close;               // ids whose OnBeforeClose ran (close-active-previous)
static int g_stale_previous = 0;                   // OnActiveTabChanged calls whose |previous| was already in g_before_close
static int g_last_active_id = -1;                  // the |active| of the last OnActiveTabChanged (an id, never a reference)
static std::vector<CefRefPtr<CefBrowserView>> g_alloy;  // rss-20-hybrid: 19 Alloy-style views beside the Chrome-style one
static std::set<int> g_loaded_ids;                 // browsers whose main frame finished loading
static int g_cdp_id = 0;
static bool g_done = false, g_started = false;
static bool g_window_gone = false;                 // WinDelegate::OnWindowDestroyed ran
static int g_tab_closed = 0, g_closed_id = -1;     // OnTabClosed count and the last |tab| id (ids, never references)
static int g_first_created = 0, g_first_last_id = -1;  // OnAfterCreated seen by the first tab's client (Client)
static int g_client_created[2] = {0, 0}, g_client_id[2] = {-1, -1};  // per-tab-client: OnAfterCreated per TabClient
static std::map<int, std::function<void(NSDictionary*)>> g_pending;
static std::function<void(NSDictionary*)> g_event_hook;  // CDP events (messages without an id), set by the store checks

// A crash must not reach macOS (.ips report, Problem Reporter window): print one line and leave with 128+signal.
static void CrashHandler(int sig, siginfo_t* si, void* uc) {
  alarm(3);  // backtrace() can allocate and hang inside a malloc crash; SIGALRM's default action ends the process
  char b[] = "PROBE crash signal=00\n";
  b[19] = '0' + sig / 10; b[20] = '0' + sig % 10;
  write(1, b, sizeof b - 1);
  char d[160];  // fault address and registers: tells a null call (pc=0) from a bad read
  ucontext_t* c = (ucontext_t*)uc;
  int n = snprintf(d, sizeof d, "PROBE crash fault_addr=%p pc=0x%llx lr=0x%llx\n", si->si_addr, (unsigned long long)c->uc_mcontext->__ss.__pc, (unsigned long long)c->uc_mcontext->__ss.__lr);
  write(1, d, n);
  void* frames[48];  // not strictly async-signal-safe, but the process is about to die anyway
  backtrace_symbols_fd(frames, backtrace(frames, 48), 1);
  _exit(128 + sig);
}
static void InstallCrashHandlers() {
  // An alternate stack lets the handler run after a stack overflow too.
  static char altstack[64 * 1024];
  stack_t ss = {.ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0};
  sigaltstack(&ss, nullptr);
  struct sigaction sa = {};
  sa.sa_sigaction = CrashHandler;
  sa.sa_flags = SA_ONSTACK | SA_SIGINFO;
  sigemptyset(&sa.sa_mask);
  for (int sig : {SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL}) sigaction(sig, &sa, nullptr);
}

// Names of this probe's crash reports (app and helpers) in ~/Library/Logs/DiagnosticReports.
static NSSet<NSString*>* CrashReports() {
  NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/DiagnosticReports"];
  NSMutableSet* out = [NSMutableSet set];
  for (NSString* n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
    if ([n hasPrefix:@"Noche Probe"] && [n hasSuffix:@".ips"]) [out addObject:n];
  return out;
}
static NSSet<NSString*>* g_reports_at_start;

// Alpha guard (installed at the top of main(), before CEF starts): every window of the probe process stays alpha 0 and
// click-through, whoever orders it in. Chromium can order a popup child window in at alpha 1 on first show
// (native_widget_ns_window_bridge.mm:1037-1047, 2107-2109), before any update notification, so setAlphaValue: is clamped
// and each order-in primitive zeroes the window first. It only zeroes alpha and ignores mouse events: it does not stop
// activation or key status (see the activation guard below and ActivationProblem in actions.mm).
// Off only for NOCHE_PROBE_VISIBLE=1 (owner-approved visible runs).
#import <objc/runtime.h>
static int g_guard_calls = 0;
static void (*orig_setAlpha)(id, SEL, CGFloat);
static void (*orig_orderWindow)(id, SEL, NSWindowOrderingMode, NSInteger);
static void (*orig_orderFront)(id, SEL, id);
static void (*orig_orderBack)(id, SEL, id);
static void (*orig_orderFrontRegardless)(id, SEL);
static void (*orig_makeKeyAndOrderFront)(id, SEL, id);
static int g_browser_window_orders = 0;  // order-in/makeKey attempts on a BrowserNativeWidgetWindow (the stray install window)
static void GuardWindow(id w, const char* sel) {
  g_guard_calls++;
  if (!strcmp(class_getName([w class]), "BrowserNativeWidgetWindow")) g_browser_window_orders++;
  const double before = [(NSWindow*)w alphaValue];
  orig_setAlpha(w, @selector(setAlphaValue:), 0);
  [(NSWindow*)w setIgnoresMouseEvents:YES];
  // One line per order-in: which selector, which window class, alpha before and after (proof that nothing shows at alpha 1).
  fprintf(stderr, "[PROBE] GUARD %s class=%s alpha before=%.2f after=%.2f children=%lu parent=%d\n", sel, class_getName([w class]), before, [(NSWindow*)w alphaValue], (unsigned long)[(NSWindow*)w childWindows].count, [(NSWindow*)w parentWindow] != nil);
  fflush(stderr);
  // Also on stdout so the run script keeps it: the popup's first order-in must show alpha after=0.
  printf("PROBE %s info guard %s class=%s alpha before=%.2f after=%.2f parent=%d\n", g_check.UTF8String, sel, class_getName([w class]), before, [(NSWindow*)w alphaValue], [(NSWindow*)w parentWindow] != nil);
  fflush(stdout);
}
static void swz_setAlpha(id self, SEL c, CGFloat) { g_guard_calls++; orig_setAlpha(self, c, 0); }
static void swz_orderWindow(id self, SEL c, NSWindowOrderingMode m, NSInteger r) { GuardWindow(self, "orderWindow:relativeTo:"); orig_orderWindow(self, c, m, r); }
static void swz_orderFront(id self, SEL c, id a) { GuardWindow(self, "orderFront:"); orig_orderFront(self, c, a); }
static void swz_orderBack(id self, SEL c, id a) { GuardWindow(self, "orderBack:"); orig_orderBack(self, c, a); }
static void swz_orderFrontRegardless(id self, SEL c) { GuardWindow(self, "orderFrontRegardless"); orig_orderFrontRegardless(self, c); }
static void swz_makeKeyAndOrderFront(id self, SEL c, id a) { GuardWindow(self, "makeKeyAndOrderFront:"); orig_makeKeyAndOrderFront(self, c, a); }
template <typename F> static void Swizzle(SEL sel, F** orig, F* repl) {
  Method m = class_getInstanceMethod(NSWindow.class, sel);
  *orig = (F*)method_getImplementation(m);
  method_setImplementation(m, (IMP)repl);
}
// Activation guard (task B4): the Web Store install ends in ScopedTabbedBrowserDisplayer::~ScopedTabbedBrowserDisplayer
// -> BrowserView::Show -> NativeWidgetNSWindowBridge::SetVisibilityState(kShowAndActivateWindow) ->
// [NSApp activateIgnoringOtherApps:YES] (native_widget_ns_window_bridge.mm:1075-1083), which would take focus from the
// owner. Every NSApplication/NSRunningApplication activation call is a counted no-op in this process. Install sheets get
// alpha 0 before they are shown (AppKit sheets are separate windows, not covered by the ordering swizzles), and a timer
// zeroes the alpha of any window that slipped through.
static int g_activate_blocked = 0;
static bool g_activation_guard = false;
static void (*orig_beginSheet)(id, SEL, NSWindow*, id);
static void swz_activateIgnoring(id, SEL, BOOL) { g_activate_blocked++; fprintf(stderr, "[PROBE] GUARD activateIgnoringOtherApps blocked\n"); }
static void swz_activate(id, SEL) { g_activate_blocked++; fprintf(stderr, "[PROBE] GUARD activate blocked\n"); }
static BOOL swz_activateWithOptions(id, SEL, NSApplicationActivationOptions) { g_activate_blocked++; fprintf(stderr, "[PROBE] GUARD activateWithOptions blocked\n"); return NO; }
static void swz_beginSheet(id self, SEL c, NSWindow* sheet, id handler) {
  orig_setAlpha(sheet, @selector(setAlphaValue:), 0);
  [sheet setIgnoresMouseEvents:YES];
  g_guard_calls++;
  fprintf(stderr, "[PROBE] GUARD beginSheet class=%s alpha=%.2f\n", class_getName([sheet class]), sheet.alphaValue);
  orig_beginSheet(self, c, sheet, handler);
}
static void InstallActivationGuard() {
  Method m1 = class_getInstanceMethod(NSApplication.class, @selector(activateIgnoringOtherApps:));
  Method m2 = class_getInstanceMethod(NSApplication.class, @selector(activate));  // macOS 14+
  Method m3 = class_getInstanceMethod(NSRunningApplication.class, @selector(activateWithOptions:));
  Method m4 = class_getInstanceMethod(NSWindow.class, @selector(beginSheet:completionHandler:));
  if (!m1 || !m3 || !m4) return;  // g_activation_guard stays false: the store checks refuse to install
  method_setImplementation(m1, (IMP)swz_activateIgnoring);
  if (m2) method_setImplementation(m2, (IMP)swz_activate);
  method_setImplementation(m3, (IMP)swz_activateWithOptions);
  orig_beginSheet = (void (*)(id, SEL, NSWindow*, id))method_getImplementation(m4);
  method_setImplementation(m4, (IMP)swz_beginSheet);
  g_activation_guard = true;
  // Backstop: any window of this process at alpha > 0 is zeroed within 5 ms (common modes, so sheet animations are covered).
  NSTimer* t = [NSTimer timerWithTimeInterval:0.005 repeats:YES block:^(NSTimer*) {
    for (NSWindow* w in NSApp.windows) if (w.alphaValue != 0) { orig_setAlpha(w, @selector(setAlphaValue:), 0); w.ignoresMouseEvents = YES; }
  }];
  [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
}
static void InstallAlphaGuard() {
  Swizzle(@selector(setAlphaValue:), &orig_setAlpha, swz_setAlpha);
  Swizzle(@selector(orderWindow:relativeTo:), &orig_orderWindow, swz_orderWindow);
  Swizzle(@selector(orderFront:), &orig_orderFront, swz_orderFront);
  Swizzle(@selector(orderBack:), &orig_orderBack, swz_orderBack);
  Swizzle(@selector(orderFrontRegardless), &orig_orderFrontRegardless, swz_orderFrontRegardless);
  Swizzle(@selector(makeKeyAndOrderFront:), &orig_makeKeyAndOrderFront, swz_makeKeyAndOrderFront);
  InstallActivationGuard();
}

static void Log(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  fprintf(stderr, "[PROBE] %s\n", s.UTF8String);
  fflush(stderr);
}

static bool g_ok = false;
static void Finish(bool ok, NSString* detail) {
  if (g_done) return;
  g_done = true;
  // A helper (GPU, utility) that crashed leaves a report even when no callback fired.
  NSMutableSet* fresh = [CrashReports() mutableCopy];
  if (g_reports_at_start) [fresh minusSet:g_reports_at_start]; else [fresh removeAllObjects];
  if (fresh.count) { ok = false; detail = [detail stringByAppendingFormat:@" child-terminated: %lu new crash report(s) %@", (unsigned long)fresh.count, fresh.allObjects]; }
  g_ok = ok;
  if (g_guard_calls) printf("PROBE %s info alpha-guard hooked calls=%d\n", g_check.UTF8String, g_guard_calls);
  if (g_activation_guard) printf("PROBE %s info activate calls blocked=%d\n", g_check.UTF8String, g_activate_blocked);
  printf("PROBE %s %s %s\n", g_check.UTF8String, ok ? "pass" : "fail", detail.UTF8String);
  fflush(stdout);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_window) g_window->Close();
    else if (!g_window_gone) exit(g_ok ? 0 : 1);  // else OnWindowDestroyed shuts down
  });
}

class Obs : public CefDevToolsMessageObserver {
 public:
  bool OnDevToolsMessage(CefRefPtr<CefBrowser>, const void* m, size_t n) override {
    NSData* d = [NSData dataWithBytes:m length:n];
    NSDictionary* j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if ([j isKindOfClass:NSDictionary.class] && !j[@"id"] && g_event_hook) { g_event_hook(j); return false; }
    if (![j isKindOfClass:NSDictionary.class] || !j[@"id"]) return false;
    auto it = g_pending.find([j[@"id"] intValue]);
    if (it == g_pending.end()) return false;
    auto cb = it->second;
    g_pending.erase(it);
    cb(j);
    return true;
  }
 private:
  IMPLEMENT_REFCOUNTING(Obs);
};

// Evaluates a JS expression in tab |b| and hands back its string value ("" when none). With |await| a
// returned Promise is awaited first.
static void EvalOn(CefRefPtr<CefBrowser> b, NSString* expr, bool await, std::function<void(NSString*)> cb) {
  if (!b) { cb(@""); return; }
  int rid = ++g_cdp_id;
  NSDictionary* msg = @{@"id" : @(rid), @"method" : @"Runtime.evaluate",
                        @"params" : @{@"expression" : expr, @"returnByValue" : @YES, @"awaitPromise" : @(await), @"userGesture" : @YES}};
  NSData* d = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
  g_pending[rid] = [cb](NSDictionary* j) {
    id v = j[@"result"][@"result"][@"value"];
    cb([v isKindOfClass:NSString.class] ? v : @"");
  };
  b->GetHost()->SendDevToolsMessage(d.bytes, d.length);
}
static void Eval(NSString* expr, std::function<void(NSString*)> cb) { EvalOn(g_browser, expr, false, cb); }

// Every tab gets a DevTools observer so EvalOn() works on any tab; the registrations live until shutdown.
static std::vector<CefRefPtr<CefRegistration>> g_regs;
static void CheckTabs(NSString* s);
static void RunTabsCheck();
static void RunRafHidden();
static ActionsHost MakeActionsHost();
static void EnsureWindowVisible(std::function<void(bool)> cb);

// Checks that need drawn frames and a window Chromium treats as visible: the latency checks, the popups, raf-visible.
static bool NeedsVisibleWindow() {
  return [g_check hasPrefix:@"switch-latency"] || [g_check hasPrefix:@"popup-"] || [g_check isEqualToString:@"raf-visible"];
}

// Shared helper: the probe window is ordered in (alpha 0, click-through, never key or active; see WinDelegate), then
// re-ordered until views::Widget::IsVisible() reads true. u10 experiment 7: a raw orderFrontRegardless leaves the Widget
// invisible (cefIsVisible=0, the compositor stays suspended); ordering the NSWindow again once it is on screen flips it.
static void EnsureWindowVisible(std::function<void(bool)> cb) {
  auto step = std::make_shared<std::function<void(int)>>();
  *step = [cb, step](int left) {
    if (g_done || !g_window) { *step = nullptr; return; }
    NSWindow* w = ((__bridge NSView*)g_window->GetWindowHandle()).window;
    w.level = NSFloatingWindowLevel;  // above other apps' normal windows, so Chromium's occlusion checker sees it uncovered
    w.ignoresMouseEvents = YES;
    [w orderWindow:NSWindowAbove relativeTo:0];  // never makeKey, never activate
    if (g_window->IsVisible() || left <= 0) {
      Log(@"WINDOW helper nsvisible=%d occlusionVisible=%d alpha=%.0f key=%d cefIsVisible=%d cefIsActive=%d appActive=%d", (int)w.isVisible, (int)((w.occlusionState & NSWindowOcclusionStateVisible) != 0), w.alphaValue, (int)w.isKeyWindow, (int)g_window->IsVisible(), (int)g_window->IsActive(), (int)NSApp.isActive);
      bool ok = g_window->IsVisible() && !g_window->IsActive() && !NSApp.isActive && !w.isKeyWindow;
      Log(@"WINDOW helper level=%ld occlusionState=0x%lx", (long)w.level, (unsigned long)w.occlusionState);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (g_window) { NSWindow* v = ((__bridge NSView*)g_window->GetWindowHandle()).window; Log(@"WINDOW 3s later level=%ld occlusionState=0x%lx occlusionVisible=%d cefIsVisible=%d key=%d appActive=%d", (long)v.level, (unsigned long)v.occlusionState, (int)((v.occlusionState & NSWindowOcclusionStateVisible) != 0), (int)g_window->IsVisible(), (int)v.isKeyWindow, (int)NSApp.isActive); }
      });
      auto f = cb; *step = nullptr; f(ok);
      return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{ (*step)(left - 1); });
  };
  (*step)(25);
}

// The content script fills dataset.nocheTabs from the service worker's answer. A view created before the
// extension finished loading misses the script (spike S1, C4b), so reload once if it stays empty.
static int g_polls = 0;
static void Poll() {
  if (g_done) return;
  Eval(@"document.documentElement.dataset.nocheTabs || ''", ^(NSString* s) {
    if (s.length) { CheckTabs(s); return; }
    if (++g_polls == 12 && g_browser) g_browser->ReloadIgnoreCache();
    if (g_polls > 60) { Finish(false, @"no answer from the service worker in 30s"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ Poll(); });
  });
}

static void CheckTabs(NSString* s) {
  NSDictionary* j = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  if (![j isKindOfClass:NSDictionary.class] || ![j[@"count"] isKindOfClass:NSNumber.class]) {
    Finish(false, [NSString stringWithFormat:@"bad answer %@", s]);
  } else if ([g_check isEqualToString:@"ext-loaded"]) {
    Finish(true, [NSString stringWithFormat:@"service worker answered %@", s]);
  } else if (![g_check isEqualToString:@"tabs-one"]) {
    auto route = [] {
      if (RunActionsCheck(g_check, MakeActionsHost())) {}
      else if ([g_check isEqualToString:@"raf-hidden"] || [g_check isEqualToString:@"raf-visible"]) RunRafHidden();
      else RunTabsCheck();
    };
    if (NeedsVisibleWindow()) EnsureWindowVisible([route](bool ok) {
      if (!ok) Finish(false, @"probe window never became a visible, inactive Widget (cefIsVisible=0 or app/window active)");
      else route();
    });
    else route();
  } else {  // tabs-one
    bool ok = [j[@"count"] intValue] == 1 && [j[@"ids"] count] == 1;
    Finish(ok, [NSString stringWithFormat:@"count=%@ ids=%@ activeId=%@", j[@"count"], [j[@"ids"] componentsJoinedByString:@","], j[@"activeId"]]);
  }
}

class BVDelegate : public CefBrowserViewDelegate {
 public:
  explicit BVDelegate(bool alloy = false) : alloy_(alloy) {}
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return alloy_ ? CEF_RUNTIME_STYLE_ALLOY : CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  void OnBrowserCreated(CefRefPtr<CefBrowserView> v, CefRefPtr<CefBrowser> b) override {
    g_created++;
    Log(@"BROWSER_CREATED id=%d total=%d", b->GetIdentifier(), g_created);
    if (!g_browser) g_browser = b;  // the first view; its callback can fire before CreateBrowserView returns
    g_regs.push_back(b->GetHost()->AddDevToolsMessageObserver(new Obs()));
  }
#ifdef NOCHE_TABS_API
  void OnTabAdded(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> tab, bool active) override {
    g_tab_added++;
    Log(@"TAB_ADDED id=%d active=%d total=%d", tab->GetIdentifier(), (int)active, g_tab_added);
  }
  void OnActiveTabChanged(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> previous, CefRefPtr<CefBrowser> active) override {
    g_active_changed++;
    g_last_active_id = active->GetIdentifier();
    const bool stale = previous && g_before_close.count(previous->GetIdentifier());
    if (stale) g_stale_previous++;
    Log(@"ACTIVE_TAB_CHANGED previous=%d active=%d%s", previous ? previous->GetIdentifier() : -1, active->GetIdentifier(), stale ? " (previous already past OnBeforeClose)" : "");
  }
  void OnTabClosed(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> tab) override {
    g_tab_closed++;
    g_closed_id = tab->GetIdentifier();
    Log(@"TAB_CLOSED id=%d total=%d", g_closed_id, g_tab_closed);
  }
#endif
 private:
  const bool alloy_;
  IMPLEMENT_REFCOUNTING(BVDelegate);
};

static void WaitFor(std::function<bool()> cond, int timeoutMs, std::function<void(bool)> done) {
  if (g_done) return;
  if (cond()) { done(true); return; }
  if (timeoutMs <= 0) { done(false); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(),
                 ^{ WaitFor(cond, timeoutMs - 100, done); });
}

static double NowMs() {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// Runs |cmd| in the extension's service worker. The content script of the first tab relays a DOM event as a
// runtime message and writes the answer to dataset.nocheReply (see Probes/fixtures/probe-extension).
static void ExtCmd(NSDictionary* cmd, std::function<void(NSDictionary*)> cb);
// On an error, asks the service worker for a plain tabs answer and adds its version ("sw", or "none" for an old script).
static void ExtCmdDiag(NSDictionary* cmd, std::function<void(NSDictionary*)> cb) {
  ExtCmd(cmd, [cmd, cb](NSDictionary* j) {
    if (!j[@"error"]) { cb(j); return; }
    ExtCmd(@{@"what" : @"tabs"}, [j, cb](NSDictionary* t) {
      NSMutableDictionary* m = [j mutableCopy];
      m[@"error"] = [NSString stringWithFormat:@"%@ (service worker version: %@, plain tabs query: %@)", j[@"error"], t[@"sw"] ?: @"none", t[@"count"] ? @"answered" : t[@"error"]];
      cb(m);
    });
  });
}

static void ExtCmd(NSDictionary* cmd, std::function<void(NSDictionary*)> cb) {
  NSData* json = [NSJSONSerialization dataWithJSONObject:@[ [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil] encoding:NSUTF8StringEncoding] ] options:0 error:nil];
  NSString* arr = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];  // ["{...}"], a JS array holding the command as a string
  NSString* js = [NSString stringWithFormat:@"delete document.documentElement.dataset.nocheReply; document.dispatchEvent(new CustomEvent('noche-cmd', {detail: %@[0]})); 'sent'", arr];
  Eval(js, [cb](NSString*) {
    auto tries = std::make_shared<int>(0);
    auto poll = std::make_shared<std::function<void()>>();
    *poll = [cb, tries, poll]() {
      if (g_done) return;
      Eval(@"document.documentElement.dataset.nocheReply || ''", [cb, tries, poll](NSString* r) {
        if (r.length) {
          NSDictionary* j = [NSJSONSerialization JSONObjectWithData:[r dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
          *poll = nullptr;  // the lambda holds itself and cb (and so CefRefPtrs): break the cycle or the tabs leak
          cb([j isKindOfClass:NSDictionary.class] ? j : @{@"error" : r});
        } else if (++*tries > 100) {
          cb(@{@"error" : @"no answer from the service worker in 10s"});
        } else {
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{ (*poll)(); });
        }
      });
    };
    (*poll)();
  });
}

static void CdpSend(NSString* method, NSDictionary* params, std::function<void(NSDictionary*)> cb) {
  if (!g_browser) return;
  int rid = ++g_cdp_id;
  NSData* d = [NSJSONSerialization dataWithJSONObject:@{@"id" : @(rid), @"method" : method, @"params" : params ?: @{}} options:0 error:nil];
  if (cb) g_pending[rid] = cb;
  // Posted: a send from inside a reply callback is dispatched synchronously and iterates the DevTools observer list
  // again (Page.frameStartedNavigating), which CHECKs (observer_list.h:192, found in the B4 override runs).
  dispatch_async(dispatch_get_main_queue(), ^{ if (g_browser) g_browser->GetHost()->SendDevToolsMessage(d.bytes, d.length); });
}
static StoreHost MakeStoreHost() {
  StoreHost h;
  h.finish = [](bool ok, NSString* d) { Finish(ok, d); };
  h.send = [](NSString* m, NSDictionary* p, std::function<void(NSDictionary*)> cb) { CdpSend(m, p, cb); };
  h.eval = [](NSString* e, bool await, std::function<void(NSString*)> cb) { dispatch_async(dispatch_get_main_queue(), ^{ EvalOn(g_browser, e, await, cb); }); };
  h.setEventHook = [](std::function<void(NSDictionary*)> f) { g_event_hook = f; };
  h.window = []() -> NSWindow* { return g_window ? ((__bridge NSView*)g_window->GetWindowHandle()).window : nil; };
  h.done = []() { return g_done; };
  h.tabCount = []() -> int {
#ifdef NOCHE_TABS_API
    return g_view ? (int)g_view->GetTabCount() : -1;
#else
    return -1;
#endif
  };
  h.ensureVisible = [](std::function<void(bool)> cb) { EnsureWindowVisible(cb); };
  h.activateBlocked = []() { return g_activate_blocked; };
  h.guardsInstalled = []() { return g_activation_guard; };
  h.browserWindowOrders = []() { return g_browser_window_orders; };
  return h;
}
static ActionsHost MakeActionsHost() {
  ActionsHost h;
  h.finish = [](bool ok, NSString* d) { Finish(ok, d); };
  h.extCmd = [](NSDictionary* c, std::function<void(NSDictionary*)> cb) { ExtCmd(c, cb); };
  h.log = [](NSString* s) { Log(@"%@", s); };
  h.view = []() { return g_view; };
  h.window = []() -> NSWindow* { return g_window ? ((__bridge NSView*)g_window->GetWindowHandle()).window : nil; };
  h.done = []() { return g_done; };
  h.url = []() { return g_url; };
  h.activateBlocked = []() { return g_activate_blocked; };
  return h;
}

// Windows the probe process owns on screen layer 0, hidden ones included (the probe's window has alpha 0).
static int WindowCount() {
  CFArrayRef a = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
  int n = 0;
  for (NSDictionary* w in (__bridge NSArray*)a)
    if ([w[(id)kCGWindowOwnerPID] intValue] == getpid() && [w[(id)kCGWindowLayer] intValue] == 0) n++;
  if (a) CFRelease(a);
  return n;
}

struct Proc { int pid, ppid; long kb; std::string cmd; };

// Summed RSS in MB (decimal) of this process and every descendant; |tree| gets the members.
static double TreeRssMB(int* procs, std::vector<Proc>* tree) {
  FILE* f = popen("/bin/ps -axo pid=,ppid=,rss=,command=", "r");
  std::map<int, Proc> all;
  char line[8192];
  while (f && fgets(line, sizeof line, f)) {
    Proc p; int off = 0;
    if (sscanf(line, "%d %d %ld %n", &p.pid, &p.ppid, &p.kb, &off) < 3) continue;
    p.cmd = line + off;
    all[p.pid] = p;
  }
  if (f) pclose(f);
  std::set<int> in{(int)getpid()};
  for (bool grew = true; grew;) {
    grew = false;
    for (auto& [pid, p] : all) if (!in.count(pid) && in.count(p.ppid)) { in.insert(pid); grew = true; }
  }
  long kb = 0;
  for (int pid : in) if (all.count(pid)) { kb += all[pid].kb; if (tree) tree->push_back(all[pid]); }
  if (procs) *procs = (int)in.size();
  return kb * 1024.0 / 1e6;
}

// Process type from the command line (renderer, gpu-process, utility:<sub-type>, ...); non-Chromium children show their command.
static std::string ProcType(const Proc& p) {
  std::string cmd = p.cmd.substr(0, p.cmd.find_last_not_of("\n") + 1);
  if (cmd.find("Noche Probe") == std::string::npos) return cmd.substr(0, 60);
  std::string type = "browser";
  size_t t = cmd.find("--type=");
  if (t != std::string::npos) type = cmd.substr(t + 7, cmd.find(' ', t) - t - 7);
  size_t u = cmd.find("--utility-sub-type=");
  if (u != std::string::npos) type += ":" + cmd.substr(u + 19, cmd.find(' ', u) - u - 19);
  if (cmd.find("--extension-process") != std::string::npos) type += "+extension";
  return type;
}

// Top 10 processes by RSS with their type.
static void PrintTop10(const char* label, std::vector<Proc> tree) {
  std::sort(tree.begin(), tree.end(), [](const Proc& a, const Proc& b) { return a.kb > b.kb; });
  for (size_t i = 0; i < tree.size() && i < 10; i++)
    printf("PROBE %s info %s rank=%zu pid=%d rss=%.1fMB type=%s\n", g_check.UTF8String, label, i + 1, tree[i].pid, tree[i].kb * 1024.0 / 1e6, ProcType(tree[i]).c_str());
  fflush(stdout);
}

// Processes in |a| whose pid is not in |b|, as "pid type" items.
static NSString* Missing(const std::vector<Proc>& a, const std::vector<Proc>& b) {
  NSMutableArray* out = [NSMutableArray array];
  for (const Proc& p : a)
    if (std::none_of(b.begin(), b.end(), [&](const Proc& q) { return q.pid == p.pid; }))
      [out addObject:[NSString stringWithFormat:@"%d %s", p.pid, ProcType(p).c_str()]];
  return out.count ? [out componentsJoinedByString:@", "] : @"none";
}

#ifdef NOCHE_TABS_API
static bool AddTabs(int n) {
  for (int i = 0; i < n; i++)
    if (!g_view->AddTab(g_url.UTF8String, nullptr, CefBrowserSettings(), nullptr, /*activate=*/false)) return false;
  return true;
}

// A client of its own for one AddTab call. Keeps ids and counts only, never a browser reference.
class TabClient : public CefClient, public CefLifeSpanHandler {
 public:
  explicit TabClient(int slot) : slot_(slot) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    g_client_created[slot_]++;
    g_client_id[slot_] = b->GetIdentifier();
  }
 private:
  const int slot_;
  IMPLEMENT_REFCOUNTING(TabClient);
};

// Records which tabs reached OnBeforeClose, for close-active-previous. Ids only.
class ClosingClient : public CefClient, public CefLifeSpanHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  void OnBeforeClose(CefRefPtr<CefBrowser> b) override { g_before_close.insert(b->GetIdentifier()); }
 private:
  IMPLEMENT_REFCOUNTING(ClosingClient);
};

static std::vector<CefRefPtr<CefBrowser>> Tabs() {
  std::vector<CefRefPtr<CefBrowser>> t;
  g_view->GetTabs(t);
  return t;
}

// Latency verdict (ruling 13). The hybrid counterparts (1 Chrome-style view plus 19 Alloy-style views, same floating
// hidden window, same URLs, warm-ups, samples and order) are the control; they always pass and write their median to a
// file in the probe's profile dir, the tab checks read it. Simplest carry-over: the probe runs one check per launch, and
// the four checks need only this one number each (printed as info beside the tab check).
static NSString* HybridFile(NSString* tabCheck) {
  return [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Application Support/Noche Probe/%@-hybrid.median", tabCheck]];
}
static void FinishLatency(double median, double p90, double lo, double hi, NSString* order) {
  NSString* base = [NSString stringWithFormat:@"median=%.1fms p90=%.1fms range=%.1f..%.1fms (30 timed after 3 warm-up, %@)", median, p90, lo, hi, order];
  if ([g_check hasSuffix:@"-hybrid"]) {  // control: info only, the number is printed beside the tab check's
    NSString* tab = [g_check substringToIndex:g_check.length - 7];
    [[NSString stringWithFormat:@"%.3f", median] writeToFile:HybridFile(tab) atomically:YES encoding:NSUTF8StringEncoding error:nil];
    Finish(true, [base stringByAppendingString:@" control only (info)"]);
    return;
  }
  NSString* path = HybridFile(g_check);
  NSDate* mtime = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
  NSString* txt = mtime ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
  NSString* info = (txt && -[mtime timeIntervalSinceNow] < 900) ? [NSString stringWithFormat:@"hybrid control median=%.1fms (info only)", txt.doubleValue] : @"no recent hybrid control (info only)";
  // Ruling 14: absolute limits, median <= 16.7 ms (one 60 Hz frame) and p90 <= 33.3 ms (two frames). Tab activation hides the outgoing
  // WebContents and waits for a fresh frame from the incoming renderer, so the Alloy SetVisible control measures a different mechanism.
  Finish(median <= 16.7 && p90 <= 33.3, [base stringByAppendingFormat:@" limits median<=16.7ms p90<=33.3ms (Ruling 14); %@; old reference 11.6ms (S1 harness) is %s", info, median <= 11.6 ? "met" : "not met"]);
}

static void SwitchStep(std::vector<CefRefPtr<CefBrowser>> tabs, std::vector<double> lat) {
  if (g_done || !g_view) return;  // the run ended (timeout) while a switch was in flight
  const size_t kWarm = 3, kTimed = 30;
  if (lat.size() == kWarm + kTimed) {
    std::vector<double> t(lat.begin() + kWarm, lat.end());
    std::sort(t.begin(), t.end());
    double median = (t[kTimed / 2 - 1] + t[kTimed / 2]) / 2, p90 = t[(size_t)(0.9 * kTimed) - 1];
    FinishLatency(median, p90, t.front(), t.back(), [g_check isEqualToString:@"switch-latency-ab"] ? @"strict A,B order" : @"fixed cycle order");
    return;
  }
  // tab 0 is active at the start. switch-latency cycles through tabs 1..19 in a fixed order; switch-latency-ab
  // is the strict A, B, A, B order, which shows a ~1 s stall on this engine after about 8 switches (see report).
  const bool ab = [g_check isEqualToString:@"switch-latency-ab"];
  CefRefPtr<CefBrowser> tab = tabs[1 + lat.size() % (ab ? 2 : 19)];
  double t0 = NowMs();
  g_view->SetActiveTab(tab);
  EvalOn(tab, @"new Promise(r => requestAnimationFrame(() => r('raf')))", true, [=](NSString* r) mutable {
    if (!r.length) { Finish(false, @"no requestAnimationFrame result; is the screen locked or the window hidden?"); return; }
    lat.push_back(NowMs() - t0);
    auto act = g_view ? g_view->GetActiveTab() : nullptr;
    const bool isActive = act && act->GetIdentifier() == tab->GetIdentifier();
    act = nullptr;
    if (!isActive) { Finish(false, [NSString stringWithFormat:@"GetActiveTab is not tab %d after SetActiveTab (switch %zu)", tab->GetIdentifier(), lat.size()]); return; }
    Log(@"SWITCH %zu tab=%d %.1f ms", lat.size(), tab->GetIdentifier(), lat.back());
    const char* gapEnv = getenv("NOCHE_PROBE_GAP_MS");  // pause between switches, default 200
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (gapEnv ? atoi(gapEnv) : 200) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ SwitchStep(tabs, lat); });
  });
}

// Stall experiments (u10). NOCHE_PROBE_MEASURE=page: a script injected over CDP before the run records, in the page,
// the epoch ms of visibilitychange to visible and of the first rAF after it. =pagestatic: the same script is in the
// served index.html (probe-engine.sh), so no CDP message touches tabs 1 and 2 until the post-run read. In both modes
// the driver awaits nothing over CDP: it switches, waits NOCHE_PROBE_GAP_MS (default 1500), switches again.
static const char* kPageJS = "(()=>{if(window.__sw)return 'dup';window.__sw=[];document.addEventListener('visibilitychange',()=>{if(document.visibilityState!=='visible')return;const v=performance.timeOrigin+performance.now();requestAnimationFrame(()=>{window.__sw.push([v,performance.timeOrigin+performance.now()])});});return 'ok'})()";
static double EpochMs() { return [NSDate date].timeIntervalSince1970 * 1000; }
static std::vector<double> g_calls;
static std::vector<CefRefPtr<CefBrowser>> g_ab;
static std::function<void(int)> g_do_switch;
static void PageAbStep();
// NOCHE_PROBE_TRACE=<file>: a Chromium trace of the switch run (viz SendBeginFrameDecision carries the throttle reason).
class EndTrace : public CefEndTracingCallback {
 public:
  explicit EndTrace(std::function<void()> f) : f_(f) {}
  void OnEndTracingComplete(const CefString&) override { f_(); }
 private:
  std::function<void()> f_;
  IMPLEMENT_REFCOUNTING(EndTrace);
};
static void FinishTraced(bool ok, NSString* detail) {
  const char* t = getenv("NOCHE_PROBE_TRACE");
  if (!t) { Finish(ok, detail); return; }
  CefEndTracing(t, new EndTrace([=] { Finish(ok, detail); }));
}
static void PageAbRead() {
  auto out = std::make_shared<std::vector<NSString*>>();
  EvalOn(g_ab[0], @"JSON.stringify(window.__sw || [])", false, [out](NSString* a) {
    out->push_back(a);
    EvalOn(g_ab[1], @"JSON.stringify(window.__sw || [])", false, [out](NSString* b) {
      out->push_back(b);
      std::vector<std::vector<std::pair<double, double>>> ev(2);
      for (int k = 0; k < 2; k++) {
        id j = [NSJSONSerialization JSONObjectWithData:[(*out)[k] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([j isKindOfClass:NSArray.class]) for (NSArray* e in j) ev[k].push_back({[e[0] doubleValue], [e[1] doubleValue]});
      }
      std::vector<double> call2raf, call2vis, vis2raf;
      NSMutableString* series = [NSMutableString string];
      size_t used[2] = {0, 0};
      for (size_t i = 0; i < g_calls.size(); i++) {
        int k = i % 2;
        while (used[k] < ev[k].size() && ev[k][used[k]].first < g_calls[i] - 50) used[k]++;
        if (used[k] >= ev[k].size()) { [series appendString:@" none"]; continue; }
        auto e = ev[k][used[k]++];
        call2vis.push_back(e.first - g_calls[i]); vis2raf.push_back(e.second - e.first); call2raf.push_back(e.second - g_calls[i]);
        [series appendFormat:@" %.0f/%.0f/%.0f", call2vis.back(), vis2raf.back(), call2raf.back()];
      }
      auto med = [](std::vector<double> v) { if (v.empty()) return -1.0; std::sort(v.begin(), v.end()); return v[v.size() / 2]; };
      g_ab.clear(); g_do_switch = nullptr;  // hold no browser reference at shutdown
      FinishTraced(!call2raf.empty() && med(call2raf) <= 11.6, [NSString stringWithFormat:@"in-page %@ switches=%zu matched=%zu median call->visible=%.1f visible->rAF=%.1f call->rAF=%.1f ms; per switch call->visible/visible->rAF/call->rAF ms:%@", [NSString stringWithUTF8String:getenv("NOCHE_PROBE_MEASURE")], g_calls.size(), call2raf.size(), med(call2vis), med(vis2raf), med(call2raf), series]);
    });
  });
}
static void PageAbStep() {
  const size_t kN = 16;
  if (g_calls.size() == kN) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ PageAbRead(); }); return; }
  const int k = g_calls.size() % 2;
  g_calls.push_back(EpochMs());
  Log(@"CALL %zu k=%d uptime_us=%llu", g_calls.size(), k, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000);
  g_do_switch(k);
  const char* gapEnv = getenv("NOCHE_PROBE_GAP_MS");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (gapEnv ? atoi(gapEnv) : 1500) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ PageAbStep(); });
}
static void LogWindowState(const char* when) {
  NSWindow* w = ((__bridge NSView*)g_window->GetWindowHandle()).window;
  Log(@"WINDOW %s nsvisible=%d occlusionVisible=%d alpha=%.0f onActiveSpace=%d cefIsVisible=%d cefIsActive=%d", when, (int)w.isVisible, (int)((w.occlusionState & NSWindowOcclusionStateVisible) != 0), w.alphaValue, (int)w.onActiveSpace, (int)g_window->IsVisible(), (int)g_window->IsActive());
}
static void PageAbStart() {
  if (getenv("NOCHE_PROBE_TRACE") && !getenv("NOCHE_PROBE_TRACE_EARLY")) CefBeginTracing("viz,cc,content,views,ui,toplevel,latency", nullptr);
  LogWindowState("before");
  if (getenv("NOCHE_PROBE_REORDER")) {
    // u10 experiment 7: order the already-visible NSWindow in a second time (never activates). The first
    // orderFrontRegardless ran while -isVisible still read NO, so Chromium's visibility bridge never saw the window
    // become visible; a second order call lets it re-read -isVisible.
    [((__bridge NSView*)g_window->GetWindowHandle()).window orderWindow:NSWindowAbove relativeTo:0];
    LogWindowState("after-reorder");
  }
  const bool injected = ![@"pagestatic" isEqualToString:@(getenv("NOCHE_PROBE_MEASURE"))];
  auto go = []{ dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ PageAbStep(); }); };
  if (!injected) { go(); return; }
  EvalOn(g_ab[0], @(kPageJS), false, [go](NSString*) { EvalOn(g_ab[1], @(kPageJS), false, [go](NSString*) { go(); }); });
}
static bool PageMode() { const char* m = getenv("NOCHE_PROBE_MEASURE"); return m && *m && strcmp(m, "cdp"); }

// Hybrid control: strict A/B between two Alloy-style views by SetVisible, measured over CDP like SwitchStep.
static int g_hybrid_visible = -1;  // switch-latency-hybrid: alloy index showing now, -1 = the Chrome-style view
static void HybridCdpStep(std::vector<double> lat) {
  if (g_done) return;
  if (lat.size() == 33) {
    g_ab.clear(); g_do_switch = nullptr;
    std::vector<double> t(lat.begin() + 3, lat.end());
    std::sort(t.begin(), t.end());
    FinishLatency((t[14] + t[15]) / 2, t[26], t.front(), t.back(), [g_check isEqualToString:@"switch-latency-ab-hybrid"] ? @"strict A,B order, SetVisible" : @"fixed cycle order, SetVisible");
    return;
  }
  const bool ab = [g_check isEqualToString:@"switch-latency-ab-hybrid"];
  const int k = ab ? lat.size() % 2 : lat.size() % 19;
  auto b = g_ab[k];
  double t0 = NowMs();
  g_do_switch(k);
  EvalOn(b, @"new Promise(r => requestAnimationFrame(() => r('raf')))", true, [=](NSString* r) mutable {
    if (!r.length) { Finish(false, @"no rAF result"); return; }
    lat.push_back(NowMs() - t0);
    Log(@"SWITCH %zu %.1f ms", lat.size(), lat.back());
    const char* gapEnv = getenv("NOCHE_PROBE_GAP_MS");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (gapEnv ? atoi(gapEnv) : 200) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ HybridCdpStep(lat); });
  });
}

static void RunTabsCheck() {
  const bool hybrid = [g_check isEqualToString:@"rss-20-hybrid"] || [g_check hasPrefix:@"switch-latency"] && [g_check hasSuffix:@"-hybrid"];  // the other 19 views already exist, Alloy style
  const bool few = [@[ @"ext-create", @"ext-activate", @"blank-link", @"per-tab-client", @"close-last", @"window-normal", @"close-active-previous" ] containsObject:g_check];
  const bool many = !few;
  int total = [g_check isEqualToString:@"tabs-bare-2"] ? 2 : many ? 20 : ([g_check isEqualToString:@"ext-activate"] ? 10 : 1);
  if ([g_check isEqualToString:@"close-last"] || [g_check isEqualToString:@"window-normal"]) total = 3;
  if (!hybrid && !AddTabs(total - 1)) { Finish(false, @"AddTab returned NULL"); return; }
  // Loading is best effort: a slow tab must not hide the check's own answer.
  WaitFor([total]{ return (int)g_loaded_ids.size() >= total; }, 15000, [total](bool loaded) {
    auto tabs = Tabs();
    if ([g_check hasPrefix:@"tabs-bare"]) {
      // Holds nothing: leaves with no CefRefPtr of its own, to tell a probe leak from an engine leak at shutdown.
      const size_t n = tabs.size();
      const bool wait = [g_check isEqualToString:@"tabs-bare-wait"];  // idle a minute first, like rss-20 does
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (wait ? 60 : 0) * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Finish(true, [NSString stringWithFormat:@"opened %d tabs, GetTabs=%zu, probe holds no references", total, n]);
      });
    } else if ([g_check isEqualToString:@"tabs-20"]) {
      ExtCmd(@{@"what" : @"tabs"}, [tabs](NSDictionary* j) {
        bool ok = [j[@"count"] intValue] == 20 && tabs.size() == 20;
        Finish(ok, [NSString stringWithFormat:@"extension count=%@ GetTabs=%zu GetTabCount=%zu OnTabAdded=%d", j[@"count"] ?: j[@"error"], tabs.size(), g_view->GetTabCount(), g_tab_added]);
      });
    } else if ([g_check isEqualToString:@"blank-link"]) {
      // OnBeforePopup is unhandled (Client has no life span handler): the link must become a tab of this view.
      const int before = WindowCount(), added0 = g_tab_added;
      const size_t beforeTabs = tabs.size();
      Eval(@"var a = document.createElement('a'); a.href = location.origin + '/?blank-link'; a.target = '_blank'; document.body.appendChild(a); a.click(); 'clicked'", [](NSString*) {});
      WaitFor([added0]{ return g_tab_added > added0; }, 8000, [before, beforeTabs](bool added) {
        // The new tab must be the link's page, not any tab that happened to appear: its committed URL carries the query.
        auto hasLink = [] {
          auto now = Tabs();
          bool found = false;
          for (auto& t : now) if (auto f = t->GetMainFrame()) if (f->GetURL().ToString().find("?blank-link") != std::string::npos) found = true;
          return found;
        };
        WaitFor(hasLink, added ? 5000 : 0, [=](bool linked) {
          const int after = WindowCount();
          const size_t afterTabs = Tabs().size();
          Finish(added && linked && after == before && afterTabs == beforeTabs + 1, [NSString stringWithFormat:@"OnTabAdded=%d new tab URL has ?blank-link=%d windows before=%d after=%d (must be unchanged) GetTabs before=%zu after=%zu (must be +1)", (int)added, (int)linked, before, after, beforeTabs, afterTabs]);
        });
      });
    } else if ([g_check isEqualToString:@"per-tab-client"]) {
      CefRefPtr<CefBrowser> a = g_view->AddTab(g_url.UTF8String, new TabClient(0), CefBrowserSettings(), nullptr, false);
      CefRefPtr<CefBrowser> b = g_view->AddTab(g_url.UTF8String, new TabClient(1), CefBrowserSettings(), nullptr, false);
      if (!a || !b) { Finish(false, @"AddTab returned NULL"); return; }
      const int aid = a->GetIdentifier(), bid = b->GetIdentifier(), firstCreated = g_first_created, tabsBefore = (int)Tabs().size();
      a = nullptr; b = nullptr;
      const bool own = g_client_created[0] == 1 && g_client_id[0] == aid && g_client_created[1] == 1 && g_client_id[1] == bid;
      // chrome.tabs.create from the extension (not Cmd+T: IDC_NEW_TAB opens a separate window, see cef_browser_view.h):
      // the tab Chrome creates itself belongs to the fallback (first tab's) client.
      const int added0 = g_tab_added, windows0 = WindowCount();
      ExtCmdDiag(@{@"what" : @"create", @"url" : g_url}, [=](NSDictionary* j) {
        if (j[@"error"]) { Finish(false, [NSString stringWithFormat:@"chrome.tabs.create failed: %@", j[@"error"]]); return; }
        WaitFor([added0]{ return g_tab_added > added0; }, 8000, [=](bool added) {
          auto now = Tabs();
          const size_t nowCount = now.size();
          int newId = -1;
          for (auto& t : now) if (t->GetIdentifier() != aid && t->GetIdentifier() != bid && !t->IsSame(g_browser)) newId = t->GetIdentifier();
          const bool fallback = added && g_first_created == firstCreated + 1 && g_first_last_id == newId && newId != -1;
          const bool still = g_client_created[0] == 1 && g_client_created[1] == 1;
          const int windows1 = WindowCount();
          now.clear();  // hold no browser reference past this point
          Finish(own && fallback && still && windows1 == windows0 && (int)nowCount == tabsBefore + 1, [NSString stringWithFormat:@"own: A=%d(id %d, want %d) B=%d(id %d, want %d); chrome.tabs.create: OnTabAdded=%d first client OnAfterCreated %d->%d last id=%d new tab id=%d; tabs=%zu windows %d->%d", g_client_created[0], g_client_id[0], aid, g_client_created[1], g_client_id[1], bid, (int)added, firstCreated, g_first_created, g_first_last_id, newId, nowCount, windows0, windows1]);
        });
      });
    } else if ([g_check isEqualToString:@"close-non-last"]) {
      if (tabs.size() != 20) { Finish(false, [NSString stringWithFormat:@"expected 20 tabs, GetTabs=%zu", tabs.size()]); return; }
      // Phase 1 closes background tab 5 of 20, phase 2 activates the new tab 5 and closes the ACTIVE tab.
      const int before = WindowCount(), closing = tabs[4]->GetIdentifier(), closed0 = g_tab_closed;
      tabs[4]->GetHost()->CloseBrowser(true);
      tabs.clear();
      WaitFor([closed0]{ return g_tab_closed > closed0; }, 8000, [before, closing](bool closed) {
        auto now = Tabs();
        const size_t n = now.size();
        bool gone = true;
        for (auto& t : now) if (t->GetIdentifier() == closing) gone = false;
        now.clear();  // hold no browser reference past this point
        const bool alive = g_window && g_view && g_view->GetActiveTab();
        const int after = WindowCount();
        ExtCmd(@{@"what" : @"tabs"}, [=](NSDictionary* j) {
          const bool p1 = closed && g_closed_id == closing && gone && alive && after == before && n == 19 && [j[@"count"] intValue] == 19;
          NSString* d1 = [NSString stringWithFormat:@"phase 1 (background tab): OnTabClosed=%d id ok=%d gone=%d window and view alive=%d windows before=%d after=%d GetTabs=%zu extension count=%@", (int)closed, (int)(g_closed_id == closing), (int)gone, (int)alive, before, after, n, j[@"count"] ?: j[@"error"]];
          if (!p1) { Finish(false, d1); return; }
          auto cur = Tabs();
          const int target = cur[4]->GetIdentifier(), active0 = g_active_changed;
          g_view->SetActiveTab(cur[4]);
          cur.clear();
          WaitFor([=]{ return g_active_changed > active0 && g_last_active_id == target; }, 5000, [=](bool activated) {
            if (!activated) { Finish(false, [d1 stringByAppendingString:@"; phase 2: tab 5 did not become active"]); return; }
            const int changed1 = g_active_changed, closed1 = g_tab_closed;
            auto c2 = Tabs();
            for (auto& t : c2) if (t->GetIdentifier() == target) t->GetHost()->CloseBrowser(true);
            c2.clear();
            WaitFor([closed1]{ return g_tab_closed > closed1; }, 8000, [=](bool closed2) {
              // .ips files appear late: wait 3 s before the verdict (Finish reads the crash reports).
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                auto after2 = Tabs();
                const size_t n2 = after2.size();
                bool gone2 = true;
                for (auto& t : after2) if (t->GetIdentifier() == target) gone2 = false;
                after2.clear();
                auto act = g_view ? g_view->GetActiveTab() : nullptr;
                const int activeId = act ? act->GetIdentifier() : -1;
                act = nullptr;
                const bool alive2 = g_window && g_view && activeId != -1;
                const bool changed = g_active_changed > changed1;
                Finish(closed2 && gone2 && activeId != target && n2 == 18 && changed && alive2 && WindowCount() == before, [NSString stringWithFormat:@"%@; phase 2 (active tab): OnTabClosed=%d gone=%d GetActiveTab id=%d (closed %d) GetTabs=%zu (want 18) OnActiveTabChanged after close=%d window alive=%d", d1, (int)closed2, (int)gone2, activeId, target, n2, (int)changed, (int)alive2]);
              });
            });
          });
        });
      });
    } else if ([g_check isEqualToString:@"close-active-previous"]) {
      // Engine review I1: close the ACTIVE tab; OnActiveTabChanged must never name as |previous| a tab whose OnBeforeClose
      // already ran (header contract: previous is NULL if it had already closed). The closing tab is an AddTab tab with its
      // own client so its OnBeforeClose is seen; it is made active first.
      CefRefPtr<CefBrowser> t = g_view->AddTab(g_url.UTF8String, new ClosingClient(), CefBrowserSettings(), nullptr, /*activate=*/true);
      if (!t) { Finish(false, @"AddTab returned NULL"); return; }
      const int target = t->GetIdentifier();
      t = nullptr;
      WaitFor([target]{ return g_last_active_id == target; }, 5000, [target](bool activated) {
        if (!activated) { Finish(false, @"the added tab did not become active"); return; }
        const int changed0 = g_active_changed, closed0 = g_tab_closed;
        auto cur = Tabs();
        for (auto& c : cur) if (c->GetIdentifier() == target) c->GetHost()->CloseBrowser(true);
        cur.clear();
        WaitFor([closed0]{ return g_tab_closed > closed0; }, 8000, [=](bool closed) {
          // The notification is a posted task: give it a second to run before judging.
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            auto act = g_view ? g_view->GetActiveTab() : nullptr;
            const int activeId = act ? act->GetIdentifier() : -1;
            act = nullptr;
            const bool changed = g_active_changed > changed0;
            Finish(closed && changed && activeId != -1 && activeId != target && g_stale_previous == 0,
                   [NSString stringWithFormat:@"closed active tab %d: OnTabClosed=%d OnActiveTabChanged after close=%d GetActiveTab id=%d; OnActiveTabChanged calls with a previous already past OnBeforeClose=%d (want 0)", target, (int)closed, (int)changed, activeId, g_stale_previous]);
          });
        });
      });
    } else if ([g_check isEqualToString:@"close-last"]) {
      // Documented behavior (cef_browser_view.h, AddTab): the window closes with the last tab. Closes all 3 tabs and
      // reports what happened; WinDelegate::OnWindowDestroyed finishes the check when the window goes.
      const int before = WindowCount(), n = (int)tabs.size();
      if (n != 3) { Finish(false, [NSString stringWithFormat:@"expected 3 tabs, GetTabs=%d", n]); return; }
      Log(@"CLOSE_LAST closing %d tabs, windows=%d", n, before);
      for (auto& t : tabs) t->GetHost()->CloseBrowser(true);
      tabs.clear();
      WaitFor([]{ return g_window_gone; }, 8000, [n](bool gone) {
        if (gone) return;
        Finish(false, [NSString stringWithFormat:@"window stayed open after %d of %d tabs closed (empty view kept, not the documented behavior)", g_tab_closed, n]);
      });
    } else if ([g_check isEqualToString:@"ext-create"]) {
      const int before = WindowCount(), added0 = g_tab_added;
      const size_t beforeTabs = Tabs().size();
      ExtCmdDiag(@{@"what" : @"create", @"url" : g_url}, [before, added0, beforeTabs](NSDictionary* j) {
        if (j[@"error"]) { Finish(false, [NSString stringWithFormat:@"chrome.tabs.create failed: %@", j[@"error"]]); return; }
        WaitFor([added0]{ return g_tab_added > added0; }, 5000, [before, beforeTabs](bool added) {
          const int after = WindowCount();
          const size_t afterTabs = Tabs().size();
          Finish(added && after == before && afterTabs == beforeTabs + 1, [NSString stringWithFormat:@"OnTabAdded=%d windows before=%d after=%d (must be unchanged) GetTabs before=%zu after=%zu (must be +1)", (int)added, before, after, beforeTabs, afterTabs]);
        });
      });
    } else if ([g_check isEqualToString:@"window-normal"]) {
      // P5: the views-hosted Browser must be a "normal" window for the extension. rawTypes is what it sees today (info).
      const size_t n = tabs.size();
      ExtCmdDiag(@{@"what" : @"windowNormal"}, [n](NSDictionary* j) {
        if (j[@"error"]) { Finish(false, [NSString stringWithFormat:@"%@", j[@"error"]]); return; }
        printf("PROBE %s info raw window types seen by the extension: %s\n", g_check.UTF8String, [[j[@"rawTypes"] componentsJoinedByString:@","] UTF8String]);
        fflush(stdout);
        NSArray* wins = j[@"wins"];
        const size_t viewTabs = g_view->GetTabCount();
        const bool oneWin = wins.count == 1 && [wins[0][@"tabs"] intValue] == (int)viewTabs;
        const bool query = [j[@"qNormal"] intValue] == (int)viewTabs && [j[@"qAll"] intValue] == (int)viewTabs;
        Finish(n >= 2 && viewTabs == n && oneWin && query, [NSString stringWithFormat:@"windows.getAll normal=%lu (window tabs %@) tabs.query normal=%@ query all=%@ GetTabCount=%zu GetTabs=%zu", (unsigned long)wins.count, wins.count ? wins[0][@"tabs"] : @"-", j[@"qNormal"], j[@"qAll"], viewTabs, n]);
      });
    } else if ([g_check isEqualToString:@"ext-activate"]) {
      if (tabs.size() != 10) { Finish(false, [NSString stringWithFormat:@"expected 10 tabs, GetTabs=%zu", tabs.size()]); return; }
      CefRefPtr<CefBrowser> tab7 = tabs[6];
      g_active_changed = 0;
      ExtCmdDiag(@{@"what" : @"activate", @"n" : @7}, [tab7](NSDictionary* j) {
        if (j[@"error"]) { Finish(false, [NSString stringWithFormat:@"chrome.tabs.update failed: %@", j[@"error"]]); return; }
        WaitFor([]{ return g_active_changed >= 1; }, 5000, [tab7](bool changed) {
          auto active = g_view->GetActiveTab();
          bool isTab7 = active && active->IsSame(tab7), cbTab7 = g_last_active_id == tab7->GetIdentifier();
          Finish(changed && isTab7 && cbTab7, [NSString stringWithFormat:@"OnActiveTabChanged=%d GetActiveTab is tab 7=%d callback active is tab 7=%d", g_active_changed, (int)isTab7, (int)cbTab7]);
        });
      });
    } else if ([g_check isEqualToString:@"switch-latency-hybrid"]) {
      if (!loaded || g_alloy.size() != 19) { Finish(false, @"hybrid views did not all load"); return; }
      // Same shape as switch-latency: the Chrome-style view plays tab 0 (showing), the 19 Alloy views the other 19 tabs.
      for (auto& v : g_alloy) v->SetVisible(false);
      g_hybrid_visible = -1;
      for (auto& v : g_alloy) g_ab.push_back(v->GetBrowser());
      g_do_switch = [](int k) {
        if (g_hybrid_visible < 0) g_view->SetVisible(false); else g_alloy[g_hybrid_visible]->SetVisible(false);
        g_alloy[k]->SetVisible(true);
        g_hybrid_visible = k;
      };
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ HybridCdpStep({}); });
    } else if ([g_check isEqualToString:@"switch-latency-ab-hybrid"]) {
      if (!loaded || g_alloy.size() != 19) { Finish(false, @"hybrid views did not all load"); return; }
      g_view->SetVisible(false);
      for (size_t i = 0; i < g_alloy.size(); i++) g_alloy[i]->SetVisible(i == 2);
      g_ab = {g_alloy[0]->GetBrowser(), g_alloy[1]->GetBrowser()};
      g_do_switch = [](int k) { g_alloy[1 - k]->SetVisible(false); g_alloy[k]->SetVisible(true); };
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (PageMode()) PageAbStart(); else HybridCdpStep({});
      });
    } else if ([g_check hasPrefix:@"switch-latency"]) {
      if (tabs.size() != 20) { Finish(false, [NSString stringWithFormat:@"expected 20 tabs, GetTabs=%zu", tabs.size()]); return; }
      if (!loaded) { Finish(false, [NSString stringWithFormat:@"only %d of 20 tabs loaded", (int)g_loaded_ids.size()]); return; }
      if (PageMode() && [g_check isEqualToString:@"switch-latency-ab"]) {
        g_ab = {tabs[1], tabs[2]};
        g_do_switch = [](int k) { g_view->SetActiveTab(g_ab[k]); };
        PageAbStart();
        return;
      }
      SwitchStep(tabs, {});
    } else {  // rss-20 and rss-20-hybrid
      if (!loaded) { Finish(false, [NSString stringWithFormat:@"only %d of %d tabs loaded", (int)g_loaded_ids.size(), total]); return; }
      int p1 = 0;
      std::vector<Proc> tree1;
      double r1 = TreeRssMB(&p1, &tree1);
      Log(@"RSS sample 1: %.1f MB, %d processes, %d loaded of %d", r1, p1, (int)g_loaded_ids.size(), total);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        int p2 = 0;
        std::vector<Proc> tree;
        double r2 = TreeRssMB(&p2, &tree);
        PrintTop10("sample2", tree);
        printf("PROBE %s info processes gone after sample 1: %s; new at sample 2: %s\n", g_check.UTF8String, Missing(tree1, tree).UTF8String, Missing(tree, tree1).UTF8String);
        fflush(stdout);
        if (p2 < p1 - 1) { Finish(false, [NSString stringWithFormat:@"a child process went away: %d processes at sample 1, %d at sample 2", p1, p2]); return; }
        Finish(std::max(r1, r2) <= 6400,  // M0 hybrid control under these flags measured 5364 to 5426 MB (rss-20-hybrid); plus 20 percent
                [NSString stringWithFormat:@"rss=%.1f MB then %.1f MB (%d then %d processes, %d loaded) limit=6400 MB (U6, hybrid control 5364-5426 MB)", r1, r2, p1, p2, (int)g_loaded_ids.size()]);
      });
    }
  });
}
#else
static void RunTabsCheck() { Finish(false, @"built without NOCHE_TABS_API (needs the B2 engine)"); }
#endif

// Needs only the stock API: tab 0 awaits one requestAnimationFrame. Settles whether a hidden window renders.
static void RunRafHidden() {
  EvalOn(g_browser, @"new Promise(r => requestAnimationFrame(() => r('raf')))", true, [](NSString* r) {
    Finish(r.length > 0, [NSString stringWithFormat:@"requestAnimationFrame %@", r.length ? @"resolved" : @"returned nothing"]);
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(),
                 ^{ Finish(false, @"requestAnimationFrame did not resolve in 10s while hidden"); });
}

// The first tab's client. OnBeforePopup is deliberately not implemented (blank-link), but OnAfterCreated is counted so
// per-tab-client can tell which tabs got this fallback client.
class Client : public CefClient, public CefLoadHandler, public CefRequestHandler, public CefLifeSpanHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> b) override { g_first_created++; g_first_last_id = b->GetIdentifier(); }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  // cef_request_handler.h:260. The only child-exit callback in 156 (no GPU or utility one); other helpers are
  // caught by the new-crash-report check in Finish().
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser>, TerminationStatus status, int, const CefString& why) override {
    Log(@"RENDER_TERMINATED status=%d %s", (int)status, why.ToString().c_str());
    Finish(false, [NSString stringWithFormat:@"child-terminated status=%d", (int)status]);
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode c, const CefString& t, const CefString& u) override {
    Log(@"LOADERROR code=%d %s %s", (int)c, t.ToString().c_str(), u.ToString().c_str());
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, int status) override {
    if (!f->IsMain()) return;
    g_loaded_ids.insert(b->GetIdentifier());
    if (g_started) return;
    Log(@"LOADEND status=%d url=%s", status, f->GetURL().ToString().c_str());
    g_started = true;
    if (IsStoreCheck(g_check)) { RunStoreCheck(g_check, MakeStoreHost()); return; }
    Poll();
  }
 private:
  IMPLEMENT_REFCOUNTING(Client);
};

class WinDelegate : public CefWindowDelegate {
 public:
  void OnWindowCreated(CefRefPtr<CefWindow> w) override {
    g_window = w;
    w->AddChildView(g_view);
    for (auto& v : g_alloy) w->AddChildView(v);
    // Invisible and inert: never shown or activated; the NSWindow exists already, so hide it before anything draws.
    NSWindow* nw = ((__bridge NSView*)w->GetWindowHandle()).window;
    // NOCHE_PROBE_VISIBLE=1 is for owner-approved runs only: opaque, still click-through, never key or active.
    nw.alphaValue = [@"1" isEqualToString:@(getenv("NOCHE_PROBE_VISIBLE") ?: "")] ? 1 : 0;  // only the value "1"
    nw.ignoresMouseEvents = YES;
    // CefWindow::Show() ends in NSApp activateIgnoringOtherApps (native_widget_ns_window_bridge.mm, kShowAndActivateWindow),
    // which is forbidden here. Ordering the NSWindow in directly never activates the app or makes the window key.
    // Both latency checks need drawn frames: viz throttles a never-drawn sink to 1 BeginFrame/s after 3 undrawn frames.
    if (!getenv("NOCHE_PROBE_NO_ORDER") && NeedsVisibleWindow()) [nw orderFrontRegardless];  // EnsureWindowVisible() finishes the job
  }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(120, 120, 1000, 700); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    g_window_gone = true;
    // close-last: pending OnTabClosed callbacks may still arrive, so report a second later and shut down after that.
    const bool deferred = ([g_check isEqualToString:@"close-last"] || [g_check isEqualToString:@"popup-close-last"]) && !g_done;
    g_regs.clear(); g_alloy.clear(); g_browser = nullptr; g_view = nullptr; g_window = nullptr;
    if (deferred)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // OnTabClosed is skipped once the view is gone, so its count is info only.
        if ([g_check isEqualToString:@"popup-close-last"]) { Finish(true, @"window closed with the last tab while the extension popup was showing, no crash"); return; }
        Finish(true, [NSString stringWithFormat:@"window closed with the last tab (documented behavior), no crash; OnTabClosed=%d of 3 (info only)", g_tab_closed]);
      });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, deferred ? 2 * NSEC_PER_SEC : 0), dispatch_get_main_queue(), ^{ [NCEngine shutdown]; exit(g_ok ? 0 : 1); });
  }
 private:
  IMPLEMENT_REFCOUNTING(WinDelegate);
};

@interface ProbeDelegate : NSObject <NSApplicationDelegate>
@end
@implementation ProbeDelegate
- (void)tryToTerminateApplication:(id)sender { if (g_window) g_window->Close(); }
- (void)applicationDidFinishLaunching:(NSNotification*)n {
  NSString* url = @"about:blank";
  for (NSString* a in NSProcessInfo.processInfo.arguments)
    if ([a hasPrefix:@"--url="]) url = [a substringFromIndex:6];
  g_url = url;
  NSString* cache = IsStoreCheck(g_check) ? StoreCachePath() : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Probe"];
  [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
  // The probe's own profile keeps the service worker script from the first run (a manifest version bump does not
  // replace it, seen as "service worker version: none"), so drop its registration before every start.
  [NSFileManager.defaultManager removeItemAtPath:[cache stringByAppendingPathComponent:@"Default/Service Worker"] error:nil];
  // Store checks start from an empty profile so "Add to Chrome" is offered every run (the install persists in Default).
  // An install left in the shared profile once added uBlock Origin Lite's processes to rss-20 (m05-probe-run.txt).
  if (IsStoreCheck(g_check)) [NSFileManager.defaultManager removeItemAtPath:[cache stringByAppendingPathComponent:@"Default"] error:nil];
  NSError* err = nil;
  if (![NCEngine startWithCachePath:cache error:&err]) { Finish(false, [NSString stringWithFormat:@"engine start failed: %@", err]); return; }
  if (getenv("NOCHE_PROBE_TRACE") && getenv("NOCHE_PROBE_TRACE_EARLY")) CefBeginTracing("viz,cc,content,views,ui,toplevel,latency", nullptr);
  InstallCrashHandlers();  // after CefInitialize, so Chromium's own handlers do not replace them
  g_reports_at_start = CrashReports();
  // test-only: --probe-selfcrash aborts, --probe-selfcrash=segv writes through a null pointer
  for (NSString* a in NSProcessInfo.processInfo.arguments) {
    if (![a hasPrefix:@"--probe-selfcrash"]) continue;
    const bool segv = [a isEqualToString:@"--probe-selfcrash=segv"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if (segv) *(volatile int*)nullptr = 1; else abort();
    });
  }
  g_view = CefBrowserView::CreateBrowserView(new Client(), url.UTF8String, CefBrowserSettings(), nullptr, nullptr, new BVDelegate());
  if ([g_check isEqualToString:@"rss-20-hybrid"] || ([g_check hasPrefix:@"switch-latency"] && [g_check hasSuffix:@"-hybrid"]))  // the M0 S1 hybrid layout: 1 Chrome-style view plus 19 Alloy-style ones
    for (int i = 1; i < 20; i++)
      g_alloy.push_back(CefBrowserView::CreateBrowserView(new Client(), url.UTF8String, CefBrowserSettings(), nullptr, nullptr, new BVDelegate(true)));
  CefWindow::CreateTopLevelWindow(new WinDelegate());
  // Own watchdog; the script has an outer one on top. rss-20 waits a minute between its two samples.
  const int watchdog = ([g_check hasPrefix:@"rss-20"] || [g_check isEqualToString:@"tabs-bare-wait"] || IsStoreCheck(g_check)) ? 150 : 40;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, watchdog * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Finish(false, @"timeout"); });
}
@end

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    for (int i = 1; i < argc; i++)
      if (strncmp(argv[i], "--probe=", 8) == 0) g_check = @(argv[i] + 8);
    if (!g_check) { printf("PROBE - fail usage: --probe=<check>\n"); return 2; }
    // Before CEF starts. Visible mode (owner-approved, exactly "1") is the only way out.
    if (![@"1" isEqualToString:@(getenv("NOCHE_PROBE_VISIBLE") ?: "")]) {
      InstallAlphaGuard();
      printf("PROBE %s info alpha-guard active (setAlphaValue clamped to 0; orderWindow:relativeTo:, orderFront:, orderBack:, orderFrontRegardless, makeKeyAndOrderFront: zero alpha and ignore mouse first)\n", g_check.UTF8String);
      fflush(stdout);
    }
    if (![@[ @"ext-loaded", @"tabs-one", @"tabs-20", @"ext-create", @"ext-activate", @"switch-latency", @"switch-latency-ab", @"switch-latency-ab-hybrid", @"switch-latency-hybrid", @"rss-20", @"rss-20-hybrid", @"tabs-bare", @"tabs-bare-2", @"tabs-bare-wait", @"raf-hidden", @"blank-link", @"per-tab-client", @"close-non-last", @"close-last", @"window-normal", @"raf-visible", @"actions-list", @"badge-observer", @"popup-anchor", @"popup-tabid", @"popup-closes", @"popup-close-last", @"close-active-previous" ] containsObject:g_check] && !IsStoreCheck(g_check)) {
      printf("PROBE %s fail unknown\n", g_check.UTF8String);
      return 1;
    }
    // CEF logs to stderr (--enable-logging=stderr); keep it in a file so the check can read its own log.
    g_logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Probe/probe.log"];
    [NSFileManager.defaultManager createDirectoryAtPath:g_logPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    freopen(g_logPath.fileSystemRepresentation, "w", stderr);
    // Quiet switches go in through argv: NCEngine hands it to CefInitialize, and the bridge's own
    // OnBeforeCommandLineProcessing adds disable-features=MacAppCodeSignClone (merging any existing value).
    static std::vector<const char*> av(argv, argv + argc);
    // NOCHE_PROBE_NO_AF=1 drops the three anti-throttling switches (u10 experiment 1).
    for (const char* f : {"--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
                          "--disable-background-timer-throttling", "--mute-audio"})
      if (!getenv("NOCHE_PROBE_NO_AF") || !strcmp(f, "--mute-audio")) av.push_back(f);
    av.push_back(nullptr);
    static char** avp = const_cast<char**>(av.data());
    static int ac = (int)av.size() - 1;
    *_NSGetArgv() = avp;
    *_NSGetArgc() = ac;
    NCApplication* app = (NCApplication*)NCApplication.sharedApplication;
    static ProbeDelegate* d = [ProbeDelegate new];
    app.delegate = d;
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [app run];
  }
  return 0;
}
