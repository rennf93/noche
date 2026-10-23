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
#include <unistd.h>
#include <crt_externs.h>
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

static NSString* g_check = nil;
static NSString* g_logPath = nil;
static CefRefPtr<CefWindow> g_window;
static CefRefPtr<CefBrowserView> g_view;
static CefRefPtr<CefBrowser> g_browser;  // the first tab: it carries the extension's content script
static NSString* g_url = @"about:blank";
static int g_created = 0;  // browsers the window's views reported
static int g_tab_added = 0, g_active_changed = 0;  // CefBrowserViewDelegate tab callbacks seen
static CefRefPtr<CefBrowser> g_last_active;        // the |active| of the last OnActiveTabChanged
static std::set<int> g_loaded_ids;                 // browsers whose main frame finished loading
static int g_cdp_id = 0;
static bool g_done = false, g_started = false;
static std::map<int, std::function<void(NSDictionary*)>> g_pending;

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
  g_ok = ok;
  printf("PROBE %s %s %s\n", g_check.UTF8String, ok ? "pass" : "fail", detail.UTF8String);
  fflush(stdout);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_window) g_window->Close();
    else exit(g_ok ? 0 : 1);
  });
}

class Obs : public CefDevToolsMessageObserver {
 public:
  bool OnDevToolsMessage(CefRefPtr<CefBrowser>, const void* m, size_t n) override {
    NSData* d = [NSData dataWithBytes:m length:n];
    NSDictionary* j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
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
                        @"params" : @{@"expression" : expr, @"returnByValue" : @YES, @"awaitPromise" : @(await)}};
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
    if ([g_check isEqualToString:@"raf-hidden"]) RunRafHidden(); else RunTabsCheck();
  } else {  // tabs-one
    bool ok = [j[@"count"] intValue] == 1 && [j[@"ids"] count] == 1;
    Finish(ok, [NSString stringWithFormat:@"count=%@ ids=%@ activeId=%@", j[@"count"], [j[@"ids"] componentsJoinedByString:@","], j[@"activeId"]]);
  }
}

class BVDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
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
    g_last_active = active;
    Log(@"ACTIVE_TAB_CHANGED previous=%d active=%d", previous ? previous->GetIdentifier() : -1, active->GetIdentifier());
  }
  void OnTabClosed(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> tab) override {
    Log(@"TAB_CLOSED id=%d", tab->GetIdentifier());
  }
#endif
 private:
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

// Windows the probe process owns on screen layer 0, hidden ones included (the probe's window has alpha 0).
static int WindowCount() {
  CFArrayRef a = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
  int n = 0;
  for (NSDictionary* w in (__bridge NSArray*)a)
    if ([w[(id)kCGWindowOwnerPID] intValue] == getpid() && [w[(id)kCGWindowLayer] intValue] == 0) n++;
  if (a) CFRelease(a);
  return n;
}

// Summed RSS in MB (decimal) of this process and every descendant.
static double TreeRssMB(int* procs) {
  FILE* f = popen("/bin/ps -axo pid=,ppid=,rss=", "r");
  std::map<int, std::pair<int, long>> all;  // pid -> (ppid, rss KB)
  int pid, ppid; long rss;
  while (f && fscanf(f, "%d %d %ld", &pid, &ppid, &rss) == 3) all[pid] = {ppid, rss};
  if (f) pclose(f);
  std::set<int> tree{(int)getpid()};
  for (bool grew = true; grew;) {
    grew = false;
    for (auto& [p, v] : all) if (!tree.count(p) && tree.count(v.first)) { tree.insert(p); grew = true; }
  }
  long kb = 0;
  for (int p : tree) if (all.count(p)) kb += all[p].second;
  if (procs) *procs = (int)tree.size();
  return kb * 1024.0 / 1e6;
}

#ifdef NOCHE_TABS_API
static bool AddTabs(int n) {
  for (int i = 0; i < n; i++)
    if (!g_view->AddTab(g_url.UTF8String, nullptr, CefBrowserSettings(), nullptr, /*activate=*/false)) return false;
  return true;
}

static std::vector<CefRefPtr<CefBrowser>> Tabs() {
  std::vector<CefRefPtr<CefBrowser>> t;
  g_view->GetTabs(t);
  return t;
}

static void SwitchStep(std::vector<CefRefPtr<CefBrowser>> tabs, std::vector<double> lat) {
  if (lat.size() == 10) {
    std::vector<double> sorted = lat;
    std::sort(sorted.begin(), sorted.end());
    double median = (sorted[4] + sorted[5]) / 2;
    Finish(median <= 11.6, [NSString stringWithFormat:@"median=%.1fms range=%.1f..%.1fms limit=11.6ms (U2)", median, sorted.front(), sorted.back()]);
    return;
  }
  CefRefPtr<CefBrowser> tab = tabs[lat.size() + 1];  // tab 0 is active at the start; each step goes to a new tab
  double t0 = NowMs();
  g_view->SetActiveTab(tab);
  EvalOn(tab, @"new Promise(r => requestAnimationFrame(() => r('raf')))", true, [=](NSString* r) mutable {
    if (!r.length) { Finish(false, @"no requestAnimationFrame result; is the screen locked or the window hidden?"); return; }
    lat.push_back(NowMs() - t0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{ SwitchStep(tabs, lat); });
  });
}

static void RunTabsCheck() {
  const bool many = ![g_check isEqualToString:@"ext-create"] && ![g_check isEqualToString:@"ext-activate"];
  const int total = many ? 20 : ([g_check isEqualToString:@"ext-activate"] ? 10 : 1);
  if (!AddTabs(total - 1)) { Finish(false, @"AddTab returned NULL"); return; }
  // Loading is best effort: a slow tab must not hide the check's own answer.
  WaitFor([total]{ return (int)g_loaded_ids.size() >= total; }, 15000, [total](bool) {
    auto tabs = Tabs();
    if ([g_check isEqualToString:@"tabs-20"]) {
      ExtCmd(@{@"what" : @"tabs"}, [tabs](NSDictionary* j) {
        bool ok = [j[@"count"] intValue] == 20 && tabs.size() == 20;
        Finish(ok, [NSString stringWithFormat:@"extension count=%@ GetTabs=%zu GetTabCount=%zu OnTabAdded=%d", j[@"count"] ?: j[@"error"], tabs.size(), g_view->GetTabCount(), g_tab_added]);
      });
    } else if ([g_check isEqualToString:@"ext-create"]) {
      const int before = WindowCount(), added0 = g_tab_added;
      ExtCmd(@{@"what" : @"create", @"url" : g_url}, [before, added0](NSDictionary* j) {
        if (j[@"error"]) { Finish(false, [NSString stringWithFormat:@"chrome.tabs.create failed: %@", j[@"error"]]); return; }
        WaitFor([added0]{ return g_tab_added > added0; }, 5000, [before](bool added) {
          const int after = WindowCount();
          Finish(added && after == before, [NSString stringWithFormat:@"OnTabAdded=%d windows before=%d after=%d (must be unchanged) GetTabs=%zu", (int)added, before, after, Tabs().size()]);
        });
      });
    } else if ([g_check isEqualToString:@"ext-activate"]) {
      if (tabs.size() != 10) { Finish(false, [NSString stringWithFormat:@"expected 10 tabs, GetTabs=%zu", tabs.size()]); return; }
      CefRefPtr<CefBrowser> tab7 = tabs[6];
      g_active_changed = 0;
      ExtCmd(@{@"what" : @"activate", @"n" : @7}, [tab7](NSDictionary* j) {
        if (j[@"error"]) { Finish(false, [NSString stringWithFormat:@"chrome.tabs.update failed: %@", j[@"error"]]); return; }
        WaitFor([]{ return g_active_changed >= 1; }, 5000, [tab7](bool changed) {
          auto active = g_view->GetActiveTab();
          bool isTab7 = active && active->IsSame(tab7), cbTab7 = g_last_active && g_last_active->IsSame(tab7);
          Finish(changed && isTab7 && cbTab7, [NSString stringWithFormat:@"OnActiveTabChanged=%d GetActiveTab is tab 7=%d callback active is tab 7=%d", g_active_changed, (int)isTab7, (int)cbTab7]);
        });
      });
    } else if ([g_check isEqualToString:@"switch-latency"]) {
      if (tabs.size() != 20) { Finish(false, [NSString stringWithFormat:@"expected 20 tabs, GetTabs=%zu", tabs.size()]); return; }
      SwitchStep(tabs, {});
    } else {  // rss-20
      int p1 = 0;
      double r1 = TreeRssMB(&p1);
      Log(@"RSS sample 1: %.1f MB, %d processes, %d loaded of %d", r1, p1, (int)g_loaded_ids.size(), total);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        int p2 = 0;
        double r2 = TreeRssMB(&p2);
        Finish(std::max(r1, r2) <= 3200, [NSString stringWithFormat:@"rss=%.1f MB then %.1f MB (%d then %d processes, %d loaded) limit=3200 MB (U6)", r1, r2, p1, p2, (int)g_loaded_ids.size()]);
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

class Client : public CefClient, public CefLoadHandler {
 public:
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode c, const CefString& t, const CefString& u) override {
    Log(@"LOADERROR code=%d %s %s", (int)c, t.ToString().c_str(), u.ToString().c_str());
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, int status) override {
    if (!f->IsMain()) return;
    g_loaded_ids.insert(b->GetIdentifier());
    if (g_started) return;
    Log(@"LOADEND status=%d url=%s", status, f->GetURL().ToString().c_str());
    g_started = true;
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
    // Invisible and inert: never shown or activated; the NSWindow exists already, so hide it before anything draws.
    NSWindow* nw = ((__bridge NSView*)w->GetWindowHandle()).window;
    nw.alphaValue = 0;
    nw.ignoresMouseEvents = YES;
    // CefWindow::Show() ends in NSApp activateIgnoringOtherApps (native_widget_ns_window_bridge.mm, kShowAndActivateWindow),
    // which is forbidden here. Ordering the NSWindow in directly never activates the app or makes the window key.
    if (!getenv("NOCHE_PROBE_NO_ORDER") && [g_check isEqualToString:@"switch-latency"]) [nw orderFrontRegardless];
  }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(120, 120, 1000, 700); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    g_regs.clear(); g_browser = nullptr; g_last_active = nullptr; g_view = nullptr; g_window = nullptr;
    dispatch_async(dispatch_get_main_queue(), ^{ [NCEngine shutdown]; exit(g_ok ? 0 : 1); });
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
  NSString* cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Probe"];
  [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
  NSError* err = nil;
  if (![NCEngine startWithCachePath:cache error:&err]) { Finish(false, [NSString stringWithFormat:@"engine start failed: %@", err]); return; }
  g_view = CefBrowserView::CreateBrowserView(new Client(), url.UTF8String, CefBrowserSettings(), nullptr, nullptr, new BVDelegate());
  CefWindow::CreateTopLevelWindow(new WinDelegate());
  // Own watchdog; the script has an outer one on top. rss-20 waits a minute between its two samples.
  const int watchdog = [g_check isEqualToString:@"rss-20"] ? 120 : 40;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, watchdog * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Finish(false, @"timeout"); });
}
@end

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    for (int i = 1; i < argc; i++)
      if (strncmp(argv[i], "--probe=", 8) == 0) g_check = @(argv[i] + 8);
    if (!g_check) { printf("PROBE - fail usage: --probe=<check>\n"); return 2; }
    if (![@[ @"ext-loaded", @"tabs-one", @"tabs-20", @"ext-create", @"ext-activate", @"switch-latency", @"rss-20", @"raf-hidden" ] containsObject:g_check]) {
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
    for (const char* f : {"--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
                          "--disable-background-timer-throttling", "--mute-audio"}) av.push_back(f);
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
