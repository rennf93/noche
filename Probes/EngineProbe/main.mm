// Engine probe: one check per launch (--probe=<check>), result as "PROBE <check> pass|fail <detail>" on stdout.
// Driven by scripts/probe-engine.sh. Chrome-style window and CDP plumbing are copied from Spikes/ChromeStyle.
#import <AppKit/AppKit.h>
#import "CefBridge.h"
#include <functional>
#include <map>
#include <string>
#include <vector>
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
static CefRefPtr<CefBrowserView> g_view, g_view2;
static CefRefPtr<CefBrowser> g_browser;
static int g_created = 0;  // browsers the window's views reported
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

// Evaluates a JS expression in the page and hands back its string value ("" when none).
static void Eval(NSString* expr, std::function<void(NSString*)> cb) {
  if (!g_browser) { cb(@""); return; }
  int rid = ++g_cdp_id;
  NSDictionary* msg = @{@"id" : @(rid), @"method" : @"Runtime.evaluate",
                        @"params" : @{@"expression" : expr, @"returnByValue" : @YES}};
  NSData* d = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
  g_pending[rid] = [cb](NSDictionary* j) {
    id v = j[@"result"][@"result"][@"value"];
    cb([v isKindOfClass:NSString.class] ? v : @"");
  };
  g_browser->GetHost()->SendDevToolsMessage(d.bytes, d.length);
}

static CefRefPtr<CefRegistration> g_reg;
static void CheckTabs(NSString* s);

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
    if (!g_browser) {  // the first view; its callback can fire before CreateBrowserView returns
      g_browser = b; g_reg = b->GetHost()->AddDevToolsMessageObserver(new Obs()); }
  }
 private:
  IMPLEMENT_REFCOUNTING(BVDelegate);
};

static void RunManyBaseline() {
  g_view2 = CefBrowserView::CreateBrowserView(nullptr, "about:blank", CefBrowserSettings(), nullptr, nullptr, new BVDelegate());
  g_window->AddChildView(g_view2);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    NSString* log = [NSString stringWithContentsOfFile:g_logPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    bool refused = [log containsString:@"Cannot add multiple Chrome style BrowserViews"];
    bool one = g_created == 1;
    Finish(refused && one, [NSString stringWithFormat:@"refusal_logged=%d browsers=%d", (int)refused, g_created]);
  });
}

class Client : public CefClient, public CefLoadHandler {
 public:
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode c, const CefString& t, const CefString& u) override {
    Log(@"LOADERROR code=%d %s %s", (int)c, t.ToString().c_str(), u.ToString().c_str());
  }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> f, int status) override {
    if (!f->IsMain() || g_started) return;
    Log(@"LOADEND status=%d url=%s", status, f->GetURL().ToString().c_str());
    g_started = true;
    if ([g_check isEqualToString:@"tabs-many-baseline"]) RunManyBaseline();
    else Poll();
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
  }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(120, 120, 1000, 700); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    g_reg = nullptr; g_browser = nullptr; g_view = nullptr; g_view2 = nullptr; g_window = nullptr;
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
  NSString* cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Probe"];
  [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
  NSError* err = nil;
  if (![NCEngine startWithCachePath:cache error:&err]) { Finish(false, [NSString stringWithFormat:@"engine start failed: %@", err]); return; }
  g_view = CefBrowserView::CreateBrowserView(new Client(), url.UTF8String, CefBrowserSettings(), nullptr, nullptr, new BVDelegate());
  CefWindow::CreateTopLevelWindow(new WinDelegate());
  // Own watchdog; the script has an outer one on top.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Finish(false, @"timeout"); });
}
@end

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    for (int i = 1; i < argc; i++)
      if (strncmp(argv[i], "--probe=", 8) == 0) g_check = @(argv[i] + 8);
    if (!g_check) { printf("PROBE - fail usage: --probe=<check>\n"); return 2; }
    if (![@[ @"ext-loaded", @"tabs-one", @"tabs-many-baseline" ] containsObject:g_check]) {
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
