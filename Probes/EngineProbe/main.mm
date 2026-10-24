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
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_request_handler.h"
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

// A crash must not reach macOS (.ips report, Problem Reporter window): print one line and leave with 128+signal.
static void CrashHandler(int sig) {
  char b[] = "PROBE crash signal=00\n";
  b[19] = '0' + sig / 10; b[20] = '0' + sig % 10;
  write(1, b, sizeof b - 1);
  _exit(128 + sig);
}
static void InstallCrashHandlers() {
  // An alternate stack lets the handler run after a stack overflow too.
  static char altstack[64 * 1024];
  stack_t ss = {.ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0};
  sigaltstack(&ss, nullptr);
  struct sigaction sa = {};
  sa.sa_handler = CrashHandler;
  sa.sa_flags = SA_ONSTACK;
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
    Log(@"ACTIVE_TAB_CHANGED previous=%d active=%d", previous ? previous->GetIdentifier() : -1, active->GetIdentifier());
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

// Top 10 processes by RSS with their type from the command line (renderer, gpu-process, utility, ...).
static void PrintTop10(const char* label, std::vector<Proc> tree) {
  std::sort(tree.begin(), tree.end(), [](const Proc& a, const Proc& b) { return a.kb > b.kb; });
  for (size_t i = 0; i < tree.size() && i < 10; i++) {
    std::string type = "browser";
    size_t t = tree[i].cmd.find("--type=");
    if (t != std::string::npos) type = tree[i].cmd.substr(t + 7, tree[i].cmd.find(' ', t) - t - 7);
    size_t u = tree[i].cmd.find("--utility-sub-type=");
    if (u != std::string::npos) type += ":" + tree[i].cmd.substr(u + 19, tree[i].cmd.find(' ', u) - u - 19);
    if (tree[i].cmd.find("--extension-process") != std::string::npos) type += "+extension";
    printf("PROBE %s info %s rank=%zu pid=%d rss=%.1fMB type=%s\n", g_check.UTF8String, label, i + 1, tree[i].pid, tree[i].kb * 1024.0 / 1e6, type.c_str());
  }
  fflush(stdout);
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

static std::vector<CefRefPtr<CefBrowser>> Tabs() {
  std::vector<CefRefPtr<CefBrowser>> t;
  g_view->GetTabs(t);
  return t;
}

static void SwitchStep(std::vector<CefRefPtr<CefBrowser>> tabs, std::vector<double> lat) {
  const size_t kWarm = 3, kTimed = 30;
  if (lat.size() == kWarm + kTimed) {
    std::vector<double> t(lat.begin() + kWarm, lat.end());
    std::sort(t.begin(), t.end());
    double median = (t[kTimed / 2 - 1] + t[kTimed / 2]) / 2, p90 = t[(size_t)(0.9 * kTimed) - 1];
    Finish(median <= 11.6, [NSString stringWithFormat:@"median=%.1fms p90=%.1fms range=%.1f..%.1fms (%zu timed after %zu warm-up, fixed cycle order) limit=11.6ms (U2)", median, p90, t.front(), t.back(), kTimed, kWarm]);
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
    Log(@"SWITCH %zu tab=%d %.1f ms", lat.size(), tab->GetIdentifier(), lat.back());
    const char* gapEnv = getenv("NOCHE_PROBE_GAP_MS");  // pause between switches, default 200
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (gapEnv ? atoi(gapEnv) : 200) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ SwitchStep(tabs, lat); });
  });
}

static void RunTabsCheck() {
  const bool hybrid = [g_check isEqualToString:@"rss-20-hybrid"];  // the other 19 views already exist, Alloy style
  const bool few = [@[ @"ext-create", @"ext-activate", @"blank-link", @"per-tab-client", @"close-last" ] containsObject:g_check];
  const bool many = !few;
  int total = [g_check isEqualToString:@"tabs-bare-2"] ? 2 : many ? 20 : ([g_check isEqualToString:@"ext-activate"] ? 10 : 1);
  if ([g_check isEqualToString:@"close-last"]) total = 3;
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
        const int after = WindowCount();
        const size_t afterTabs = Tabs().size();
        Finish(added && after == before && afterTabs == beforeTabs + 1, [NSString stringWithFormat:@"OnTabAdded=%d windows before=%d after=%d (must be unchanged) GetTabs before=%zu after=%zu (must be +1)", (int)added, before, after, beforeTabs, afterTabs]);
      });
    } else if ([g_check isEqualToString:@"per-tab-client"]) {
      CefRefPtr<CefBrowser> a = g_view->AddTab(g_url.UTF8String, new TabClient(0), CefBrowserSettings(), nullptr, false);
      CefRefPtr<CefBrowser> b = g_view->AddTab(g_url.UTF8String, new TabClient(1), CefBrowserSettings(), nullptr, false);
      if (!a || !b) { Finish(false, @"AddTab returned NULL"); return; }
      const int aid = a->GetIdentifier(), bid = b->GetIdentifier(), firstCreated = g_first_created, tabsBefore = (int)Tabs().size();
      a = nullptr; b = nullptr;
      const bool own = g_client_created[0] == 1 && g_client_id[0] == aid && g_client_created[1] == 1 && g_client_id[1] == bid;
      // Cmd+T: the tab Chrome creates itself belongs to the fallback (first tab's) client.
      const int added0 = g_tab_added;
      g_browser->GetHost()->ExecuteChromeCommand(34014 /* IDC_NEW_TAB */, CEF_WOD_CURRENT_TAB);
      WaitFor([added0]{ return g_tab_added > added0; }, 8000, [=](bool added) {
        auto now = Tabs();
        const size_t nowCount = now.size();
        int newId = -1;
        for (auto& t : now) if (t->GetIdentifier() != aid && t->GetIdentifier() != bid && !t->IsSame(g_browser)) newId = t->GetIdentifier();
        const bool fallback = added && g_first_created == firstCreated + 1 && g_first_last_id == newId && newId != -1;
        const bool still = g_client_created[0] == 1 && g_client_created[1] == 1;
        now.clear();  // hold no browser reference past this point
        Finish(own && fallback && still && (int)nowCount == tabsBefore + 1, [NSString stringWithFormat:@"own: A=%d(id %d, want %d) B=%d(id %d, want %d); Cmd+T: OnTabAdded=%d first client OnAfterCreated %d->%d last id=%d new tab id=%d; tabs=%zu", g_client_created[0], g_client_id[0], aid, g_client_created[1], g_client_id[1], bid, (int)added, firstCreated, g_first_created, g_first_last_id, newId, nowCount]);
      });
    } else if ([g_check isEqualToString:@"close-non-last"]) {
      if (tabs.size() != 20) { Finish(false, [NSString stringWithFormat:@"expected 20 tabs, GetTabs=%zu", tabs.size()]); return; }
      const int before = WindowCount(), closing = tabs[4]->GetIdentifier(), closed0 = g_tab_closed;
      tabs[4]->GetHost()->CloseBrowser(true);
      tabs.clear();
      WaitFor([closed0]{ return g_tab_closed > closed0; }, 8000, [before, closing](bool closed) {
        // The closed tab is gone and the window, the view and the other 19 tabs stay.
        auto now = Tabs();
        const size_t n = now.size();
        bool gone = true;
        for (auto& t : now) if (t->GetIdentifier() == closing) gone = false;
        now.clear();  // hold no browser reference past this point
        const bool alive = g_window && g_view && g_view->GetActiveTab();
        const int after = WindowCount();
        ExtCmd(@{@"what" : @"tabs"}, [=](NSDictionary* j) {
          Finish(closed && g_closed_id == closing && gone && alive && after == before && n == 19 && [j[@"count"] intValue] == 19, [NSString stringWithFormat:@"OnTabClosed=%d id ok=%d closed tab gone=%d window and view alive=%d windows before=%d after=%d GetTabs=%zu extension count=%@", (int)closed, (int)(g_closed_id == closing), (int)gone, (int)alive, before, after, n, j[@"count"] ?: j[@"error"]]);
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
    } else if ([g_check hasPrefix:@"switch-latency"]) {
      if (tabs.size() != 20) { Finish(false, [NSString stringWithFormat:@"expected 20 tabs, GetTabs=%zu", tabs.size()]); return; }
      if (!loaded) { Finish(false, [NSString stringWithFormat:@"only %d of 20 tabs loaded", (int)g_loaded_ids.size()]); return; }
      SwitchStep(tabs, {});
    } else {  // rss-20 and rss-20-hybrid
      if (!loaded) { Finish(false, [NSString stringWithFormat:@"only %d of %d tabs loaded", (int)g_loaded_ids.size(), total]); return; }
      int p1 = 0;
      double r1 = TreeRssMB(&p1, nullptr);
      Log(@"RSS sample 1: %.1f MB, %d processes, %d loaded of %d", r1, p1, (int)g_loaded_ids.size(), total);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        int p2 = 0;
        std::vector<Proc> tree;
        double r2 = TreeRssMB(&p2, &tree);
        PrintTop10("sample2", tree);
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
    g_window_gone = true;
    // close-last: pending OnTabClosed callbacks may still arrive, so report a second later and shut down after that.
    const bool deferred = [g_check isEqualToString:@"close-last"] && !g_done;
    g_regs.clear(); g_alloy.clear(); g_browser = nullptr; g_view = nullptr; g_window = nullptr;
    if (deferred)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        Finish(g_tab_closed == 3, [NSString stringWithFormat:@"window closed with the last tab (documented behavior), no crash; OnTabClosed=%d of 3", g_tab_closed]);
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
  NSString* cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Probe"];
  [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
  // The probe's own profile keeps the service worker script from the first run (a manifest version bump does not
  // replace it, seen as "service worker version: none"), so drop its registration before every start.
  [NSFileManager.defaultManager removeItemAtPath:[cache stringByAppendingPathComponent:@"Default/Service Worker"] error:nil];
  NSError* err = nil;
  if (![NCEngine startWithCachePath:cache error:&err]) { Finish(false, [NSString stringWithFormat:@"engine start failed: %@", err]); return; }
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
  if ([g_check isEqualToString:@"rss-20-hybrid"])  // the M0 S1 hybrid layout: 1 Chrome-style view plus 19 Alloy-style ones
    for (int i = 1; i < 20; i++)
      g_alloy.push_back(CefBrowserView::CreateBrowserView(new Client(), url.UTF8String, CefBrowserSettings(), nullptr, nullptr, new BVDelegate(true)));
  CefWindow::CreateTopLevelWindow(new WinDelegate());
  // Own watchdog; the script has an outer one on top. rss-20 waits a minute between its two samples.
  const int watchdog = ([g_check hasPrefix:@"rss-20"] || [g_check isEqualToString:@"tabs-bare-wait"]) ? 120 : 40;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, watchdog * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Finish(false, @"timeout"); });
}
@end

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    for (int i = 1; i < argc; i++)
      if (strncmp(argv[i], "--probe=", 8) == 0) g_check = @(argv[i] + 8);
    if (!g_check) { printf("PROBE - fail usage: --probe=<check>\n"); return 2; }
    if (![@[ @"ext-loaded", @"tabs-one", @"tabs-20", @"ext-create", @"ext-activate", @"switch-latency", @"switch-latency-ab", @"rss-20", @"rss-20-hybrid", @"tabs-bare", @"tabs-bare-2", @"tabs-bare-wait", @"raf-hidden", @"blank-link", @"per-tab-client", @"close-non-last", @"close-last" ] containsObject:g_check]) {
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
