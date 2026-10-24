// Surfaces checks: see surfaces.h. Every check prints facts as "PROBE <check> info ..." and passes when the experiment ran.
#import "surfaces.h"
#include <chrono>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>
#import <objc/runtime.h>
#include <sys/stat.h>
#include "include/cef_id_mappers.h"
#include "include/cef_command_ids.h"

#ifndef NOCHE_TABS_API
void SurfEarly(NSString*) {}
CefRefPtr<CefContextMenuHandler> SurfContextMenuHandler() { return nullptr; }
CefRefPtr<CefDownloadHandler> SurfDownloadHandler() { return nullptr; }
CefRefPtr<CefPermissionHandler> SurfPermissionHandler() { return nullptr; }
void SurfOnLoadEnd(int, int) {}
bool RunSurfacesCheck(NSString* c, const SurfHost& h) {
  if (![@[ @"cmd-enabled", @"bubbles", @"download-restart-1", @"download-restart-2", @"download-tab-close", @"ctx-ext-items", @"zoom-scope", @"chrome-pages" ] containsObject:c]) return false;
  h.finish(false, @"built without NOCHE_TABS_API");
  return true;
}
#else

namespace {

using H = std::shared_ptr<const SurfHost>;
NSString* g_name = @"";
double g_t0 = 0;
double NowMs() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
#define PI(...) do { printf("PROBE %s info %s\n", g_name.UTF8String, [NSString stringWithFormat:__VA_ARGS__].UTF8String); fflush(stdout); } while (0)

std::map<int, int> g_load;  // browser id -> main frame load end status

void Later(double sec, std::function<void()> f) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ f(); });
}
void WaitFor(H h, int timeoutMs, std::function<bool()> cond, std::function<void(bool)> done) {
  if (h->done()) return;
  if (cond()) { done(true); return; }
  if (timeoutMs <= 0) { done(false); return; }
  Later(0.1, [=] { WaitFor(h, timeoutMs - 100, cond, done); });
}

// ---- tabs by id (no browser reference is kept across callbacks) ----
CefRefPtr<CefBrowser> ById(const H& h, int id) {
  auto v = h->view();
  std::vector<CefRefPtr<CefBrowser>> t;
  if (v) v->GetTabs(t);
  for (auto& b : t) if (b->GetIdentifier() == id) return b;
  return nullptr;
}
int AddTab(const H& h, NSString* url, bool activate) {
  auto v = h->view();
  auto b = v ? v->AddTab(url.UTF8String, nullptr, CefBrowserSettings(), nullptr, activate) : nullptr;
  return b ? b->GetIdentifier() : -1;
}
int ActiveId(const H& h) { auto v = h->view(); auto a = v ? v->GetActiveTab() : nullptr; return a ? a->GetIdentifier() : -1; }
std::vector<int> TabIds(const H& h) {
  std::vector<CefRefPtr<CefBrowser>> t;
  if (auto v = h->view()) v->GetTabs(t);
  std::vector<int> ids;
  for (auto& b : t) ids.push_back(b->GetIdentifier());
  return ids;
}
NSString* TabUrls(const H& h) {
  std::vector<CefRefPtr<CefBrowser>> t;
  if (auto v = h->view()) v->GetTabs(t);
  NSMutableArray* o = [NSMutableArray array];
  for (auto& b : t) [o addObject:[NSString stringWithFormat:@"%d=%s", b->GetIdentifier(), b->GetMainFrame()->GetURL().ToString().c_str()]];
  return [o componentsJoinedByString:@" "];
}
void Eval(const H& h, int id, NSString* js, bool await, std::function<void(NSString*)> cb) { h->eval(ById(h, id), js, await, cb); }
NSString* Localhost(NSString* u) { return [u stringByReplacingOccurrencesOfString:@"127.0.0.1" withString:@"localhost"]; }
NSString* Page(const H& h, NSString* path) { return [[NSURL URLWithString:path relativeToURL:[NSURL URLWithString:h->url()]] absoluteString]; }

void DumpWindows(const H& h, const char* label, NSSet* base) {
  for (NSWindow* w in NSApp.windows)
    PI(@"%s window class=%s frame=%@ alpha=%.2f visible=%d key=%d main=%d level=%ld parent=%d new=%d", label, class_getName([w class]), NSStringFromRect(w.frame), w.alphaValue, (int)w.isVisible, (int)w.isKeyWindow, (int)w.isMainWindow, (long)w.level, w.parentWindow != nil, base && ![base containsObject:[NSValue valueWithNonretainedObject:w]]);
  PI(@"%s counts nswindows=%lu cgwindows=%d alphaGuardCalls=%d activateBlocked=%d appActive=%d", label, (unsigned long)NSApp.windows.count, h->windowCount(), h->guardCalls(), h->activateBlocked(), (int)NSApp.isActive);
}
NSSet* WindowSet() {
  NSMutableSet* s = [NSMutableSet set];
  for (NSWindow* w in NSApp.windows) [s addObject:[NSValue valueWithNonretainedObject:w]];
  return s;
}

// ---- download handler (R6, R7) ----
struct DlEv { uint32_t id; bool inprog, complete, canceled, interrupted, paused, hasBrowser; int reason, pct; int64_t recv, total; std::string path; double t; };
std::vector<DlEv> g_dl_events;
std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> g_dl_cbs;
std::function<void(const DlEv&)> g_dl_hook;
bool g_dl_on = false, g_perm_on = false, g_ctx_on = false;
std::string DlDir() { const char* d = getenv("NOCHE_PROBE_DL_DIR"); return d ? d : ""; }
std::string DlStr(const DlEv& e) {
  char b[512];
  snprintf(b, sizeof b, "id=%u browser=%d inProgress=%d paused=%d complete=%d canceled=%d interrupted=%d reason=%d pct=%d recv=%lld total=%lld path=%s t=%.1fs", e.id, e.hasBrowser, e.inprog, e.paused, e.complete, e.canceled, e.interrupted, e.reason, e.pct, (long long)e.recv, (long long)e.total, e.path.c_str(), e.t / 1000);
  return b;
}
class DlHandler : public CefDownloadHandler {
 public:
  bool OnBeforeDownload(CefRefPtr<CefBrowser> b, CefRefPtr<CefDownloadItem> item, const CefString& name, CefRefPtr<CefBeforeDownloadCallback> cb) override {
    std::string p = DlDir() + "/" + name.ToString();
    printf("PROBE %s info OnBeforeDownload id=%u browser=%d name=%s url=%s continue-to=%s\n", g_name.UTF8String, item->GetId(), b != nullptr, name.ToString().c_str(), item->GetURL().ToString().c_str(), p.c_str());
    fflush(stdout);
    cb->Continue(p, false);
    return true;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser> b, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback> cb) override {
    DlEv e{item->GetId(), item->IsInProgress(), item->IsComplete(), item->IsCanceled(), item->IsInterrupted(), item->IsPaused(), b != nullptr, (int)item->GetInterruptReason(), item->GetPercentComplete(), item->GetReceivedBytes(), item->GetTotalBytes(), item->GetFullPath().ToString(), NowMs() - g_t0};
    bool log = g_dl_events.empty();
    if (!log) { auto& l = g_dl_events.back(); log = l.id != e.id || l.inprog != e.inprog || l.paused != e.paused || l.complete != e.complete || l.canceled != e.canceled || l.interrupted != e.interrupted || l.hasBrowser != e.hasBrowser || l.pct / 10 != e.pct / 10; }
    g_dl_events.push_back(e);
    if (cb) g_dl_cbs[e.id] = cb;
    if (log) { printf("PROBE %s info OnDownloadUpdated %s (events so far %zu)\n", g_name.UTF8String, DlStr(e).c_str(), g_dl_events.size()); fflush(stdout); }
    if (g_dl_hook) g_dl_hook(e);
  }
 private:
  IMPLEMENT_REFCOUNTING(DlHandler);
};

// ---- permission handler (R2) ----
struct Prompt { uint64_t id; std::string origin; uint32_t mask; };
std::vector<Prompt> g_prompts;
bool g_perm_deny = false;
class PermHandler : public CefPermissionHandler {
 public:
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t id, const CefString& origin, uint32_t mask, CefRefPtr<CefPermissionPromptCallback> cb) override {
    g_prompts.push_back({id, origin.ToString(), mask});
    printf("PROBE %s info OnShowPermissionPrompt id=%llu origin=%s mask=0x%x (geolocation=0x%x notifications=0x%x)\n", g_name.UTF8String, (unsigned long long)id, origin.ToString().c_str(), mask, CEF_PERMISSION_TYPE_GEOLOCATION, CEF_PERMISSION_TYPE_NOTIFICATIONS);
    fflush(stdout);
    if (!g_perm_deny) return false;
    dispatch_async(dispatch_get_main_queue(), ^{ cb->Continue(CEF_PERMISSION_RESULT_DENY); });
    return true;
  }
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t id, cef_permission_request_result_t r) override {
    printf("PROBE %s info OnDismissPermissionPrompt id=%llu result=%d\n", g_name.UTF8String, (unsigned long long)id, (int)r);
    fflush(stdout);
  }
 private:
  IMPLEMENT_REFCOUNTING(PermHandler);
};

// ---- context menu handler (R12) ----
struct CtxItem { int id; std::string label; }; 
std::function<void(CefRefPtr<CefMenuModel>, CefRefPtr<CefRunContextMenuCallback>)> g_ctx_hook;
class CtxHandler : public CefContextMenuHandler {
 public:
  bool RunContextMenu(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> p, CefRefPtr<CefMenuModel> m, CefRefPtr<CefRunContextMenuCallback> cb) override {
    if (!g_ctx_hook) return false;
    printf("PROBE %s info RunContextMenu browser=%d pageUrl=%s x=%d y=%d typeFlags=0x%x\n", g_name.UTF8String, b->GetIdentifier(), p->GetPageUrl().ToString().c_str(), p->GetXCoord(), p->GetYCoord(), (int)p->GetTypeFlags());
    g_ctx_hook(m, cb);
    return true;
  }
 private:
  IMPLEMENT_REFCOUNTING(CtxHandler);
};

CefRefPtr<DlHandler> g_dl;
CefRefPtr<PermHandler> g_perm;
CefRefPtr<CtxHandler> g_ctx;

// Releases every reference this file keeps, then ends the run.
void Done(const H& h, bool ok, NSString* d) {
  g_dl_hook = nullptr; g_ctx_hook = nullptr; g_dl_cbs.clear();
  h->finish(ok, d);
}

// ---- R1 ----
void CheckCmdEnabled(H h) {
  static NSArray* names = @[ @"IDC_NEW_TAB", @"IDC_CLOSE_TAB", @"IDC_RELOAD", @"IDC_RELOAD_BYPASSING_CACHE", @"IDC_BACK", @"IDC_FORWARD", @"IDC_FIND", @"IDC_FIND_NEXT", @"IDC_FIND_PREVIOUS", @"IDC_PRINT", @"IDC_ZOOM_PLUS", @"IDC_ZOOM_MINUS", @"IDC_ZOOM_NORMAL", @"IDC_SHOW_HISTORY", @"IDC_SHOW_DOWNLOADS", @"IDC_BOOKMARK_THIS_TAB", @"IDC_SHOW_BOOKMARK_MANAGER", @"IDC_DEV_TOOLS", @"IDC_DEV_TOOLS_CONSOLE", @"IDC_DEV_TOOLS_INSPECT", @"IDC_DEV_TOOLS_TOGGLE", @"IDC_DEV_TOOLS_DEVICES", @"IDC_VIEW_SOURCE", @"IDC_SAVE_PAGE", @"IDC_FULLSCREEN", @"IDC_FOCUS_LOCATION" ];
  auto state = [h](const char* when) {
    auto act = h->view()->GetActiveTab();
    NSMutableArray* o = [NSMutableArray array];
    for (NSString* n in names) {
      int id = cef_id_for_command_id_name(n.UTF8String);
      [o addObject:[NSString stringWithFormat:@"%@(%d)=%@", n, id, id < 0 ? @"unknown" : (act->GetHost()->CanExecuteChromeCommand(id) ? @"1" : @"0")]];
    }
    PI(@"CanExecuteChromeCommand on active tab %d (%s): %@", act->GetIdentifier(), when, [o componentsJoinedByString:@" "]);
  };
  state("fresh load, no history");
  auto first = h->first();
  first->GetMainFrame()->LoadURL(Page(h, @"/?second").UTF8String);
  Later(2.5, [=] {
    state("after a second navigation (Back possible)");
    h->first()->GoBack();
    Later(2.5, [=] {
      state("after going back (Forward possible)");
      // Unintercepted commands, one at a time, on the active tab.
      auto cmds = std::make_shared<std::vector<NSString*>>(std::vector<NSString*>{@"IDC_SHOW_HISTORY", @"IDC_SHOW_DOWNLOADS", @"IDC_SHOW_BOOKMARK_MANAGER"});
      auto step = std::make_shared<std::function<void(size_t)>>();
      *step = [=](size_t i) {
        if (i == cmds->size()) { H hh = h; *step = nullptr; Done(hh, true, @"CanExecuteChromeCommand printed for 3 states; 3 unintercepted commands executed (3 s apart), facts above"); return; }
        NSString* name = (*cmds)[i];
        int id = cef_id_for_command_id_name(name.UTF8String);
        const int win0 = h->windowCount(), tabs0 = (int)h->view()->GetTabCount();
        NSSet* base = WindowSet();
        auto before = TabIds(h);
        PI(@"exec %@ id=%d before: tabs=%d windows=%d active=%d urls: %@", name, id, tabs0, win0, ActiveId(h), TabUrls(h));
        h->view()->GetActiveTab()->GetHost()->ExecuteChromeCommand(id, CEF_WOD_CURRENT_TAB);
        Later(3, [=] {
          PI(@"exec %@ after 3s: tabs=%d windows=%d (before %d) active=%d urls: %@", name, (int)h->view()->GetTabCount(), h->windowCount(), win0, ActiveId(h), TabUrls(h));
          DumpWindows(h, "exec-after", base);
          // Close what it opened so the next command starts from the same state, then restore the first tab as active.
          for (int t : TabIds(h)) if (std::find(before.begin(), before.end(), t) == before.end()) if (auto b = ById(h, t)) b->GetHost()->CloseBrowser(true);
          Later(1.5, [=] { if (auto f = h->first()) h->view()->SetActiveTab(f); (*step)(i + 1); });
        });
      };
      (*step)(0);
    });
  });
}

// ---- R2 ----
void CheckBubbles(H h) {
  auto base = WindowSet();
  DumpWindows(h, "baseline", base);
  PI(@"zoom now: %f", h->first()->GetHost()->GetZoomLevel());
  h->first()->GetHost()->SetZoomLevel(1.0);
  Later(1.5, [=] {
    DumpWindows(h, "after-SetZoomLevel", base);
    PI(@"zoom after SetZoomLevel(1.0): %f", h->first()->GetHost()->GetZoomLevel());
    h->view()->SetActiveTab(h->first());
    h->first()->GetHost()->ExecuteChromeCommand(cef_id_for_command_id_name("IDC_ZOOM_PLUS"), CEF_WOD_CURRENT_TAB);
    Later(1.5, [=] {
      DumpWindows(h, "after-IDC_ZOOM_PLUS", base);
      PI(@"zoom after IDC_ZOOM_PLUS: %f", h->first()->GetHost()->GetZoomLevel());
      h->first()->GetHost()->SetZoomLevel(0);
      // Permission request, no handler (SurfPermissionHandler answers NULL until phase 2).
      int t1 = AddTab(h, Page(h, @"/perm.html"), true);
      if (t1 < 0) { Done(h, false, @"AddTab returned NULL"); return; }
      WaitFor(h, 10000, [=] { return g_load.count(t1) > 0; }, [=](bool) {
        Eval(h, t1, @"window.runPerm()", false, [=](NSString* r) {
          PI(@"phase 1 (no permission handler) page runPerm: %@, active tab=%d (want %d)", r, ActiveId(h), t1);
          Later(4, [=] {
            DumpWindows(h, "phase1-after-permission-request", base);
            Eval(h, t1, @"JSON.stringify(window.__perm)", false, [=](NSString* p) {
              PI(@"phase 1 page __perm after 4s: %@ (empty means prompts still pending)", p);
              PI(@"phase 1 handler calls seen: %zu (want 0, no handler installed)", g_prompts.size());
              // Phase 2: handler that denies, new origin (localhost), the pending prompt's tab closed first.
              if (auto b = ById(h, t1)) b->GetHost()->CloseBrowser(true);
              g_perm_on = true; g_perm_deny = true;
              Later(2, [=] {
                auto base2 = WindowSet();
                DumpWindows(h, "phase2-baseline", base2);
                int t2 = AddTab(h, Localhost(Page(h, @"/perm.html")), true);
                if (t2 < 0) { Done(h, false, @"AddTab returned NULL (phase 2)"); return; }
                WaitFor(h, 10000, [=] { return g_load.count(t2) > 0; }, [=](bool) {
                  Eval(h, t2, @"window.runPerm()", false, [=](NSString* r2) {
                    PI(@"phase 2 (deny handler) page runPerm: %@", r2);
                    Later(4, [=] {
                      DumpWindows(h, "phase2-after-permission-request", base2);
                      Eval(h, t2, @"JSON.stringify(window.__perm)", false, [=](NSString* p2) {
                        PI(@"phase 2 page __perm after 4s: %@ (geo err1 = PERMISSION_DENIED, notif denied)", p2);
                        uint32_t seen = 0;
                        for (auto& p : g_prompts) seen |= p.mask;
                        PI(@"phase 2 handler prompts=%zu union mask=0x%x expected geolocation|notifications=0x%x", g_prompts.size(), seen, CEF_PERMISSION_TYPE_GEOLOCATION | CEF_PERMISSION_TYPE_NOTIFICATIONS);
                        Done(h, true, @"zoom bubbles and permission bubbles recorded (no handler, then deny handler)");
                      });
                    });
                  });
                });
              });
            });
          });
        });
      });
    });
  });
}

NSString* DeepJs() {
  return @"(function(){function t(n){let s='';if(n.shadowRoot)s+=t(n.shadowRoot);for(const c of n.childNodes){if(c.nodeType===3)s+=c.textContent+' ';else if(c.nodeType===1&&!['STYLE','SCRIPT'].includes(c.tagName))s+=t(c);}return s;}return t(document.body||document).replace(/\\s+/g,' ').trim().slice(0,500);})()";
}
// ---- R6 ----
NSString* StateFile() { return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Probe/download-restart.state"]; }
NSString* DirListing() {
  NSMutableArray* o = [NSMutableArray array];
  for (NSString* n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(DlDir().c_str()) error:nil])
    [o addObject:[NSString stringWithFormat:@"%@:%llu", n, [NSFileManager.defaultManager attributesOfItemAtPath:[@(DlDir().c_str()) stringByAppendingPathComponent:n] error:nil].fileSize]];
  return o.count ? [o componentsJoinedByString:@" "] : @"(empty)";
}
unsigned long long DirBytes() {
  unsigned long long t = 0;
  for (NSString* n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(DlDir().c_str()) error:nil])
    t += [NSFileManager.defaultManager attributesOfItemAtPath:[@(DlDir().c_str()) stringByAppendingPathComponent:n] error:nil].fileSize;
  return t;
}
const char* SlowUrl() { return getenv("NOCHE_PROBE_SLOW_URL"); }

void DownloadRestart1(H h) {
  if (!SlowUrl() || DlDir().empty()) { Done(h, false, @"NOCHE_PROBE_SLOW_URL / NOCHE_PROBE_DL_DIR not set (run through probe-engine.sh)"); return; }
  auto paused = std::make_shared<bool>(false);
  g_dl_hook = [=](const DlEv& e) {
    if (!*paused && e.inprog && e.pct >= 10) {
      *paused = true;
      PI(@"pausing at pct=%d recv=%lld", e.pct, (long long)e.recv);
      g_dl_cbs[e.id]->Pause();
    }
  };
  h->eval(h->first(), [NSString stringWithFormat:@"location.href = '%s'; 'go'", SlowUrl()], false, [](NSString*) {});
  WaitFor(h, 40000, [=] { for (auto& e : g_dl_events) if (e.paused) return true; return false; }, [=](bool ok) {
    if (!ok) { Done(h, false, @"download never reached 10 percent and a paused state in 40 s"); return; }
    Later(2.5, [=] {
      DlEv last = g_dl_events.back();
      PI(@"before quit: %s files: %@", DlStr(last).c_str(), DirListing());
      NSString* st = [NSString stringWithFormat:@"id=%u recv=%lld total=%lld path=%s", last.id, (long long)last.recv, (long long)last.total, last.path.c_str()];
      [st writeToFile:StateFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
      Done(h, true, [NSString stringWithFormat:@"launch 1: paused download state saved (%@), quitting with it paused", st]);
    });
  });
}

void DownloadRestart2(H h) {
  if (DlDir().empty()) { Done(h, false, @"NOCHE_PROBE_DL_DIR not set"); return; }
  NSString* st = [NSString stringWithContentsOfFile:StateFile() encoding:NSUTF8StringEncoding error:nil];
  if (!st) { Done(h, false, @"no state file from launch 1 (run download-restart-1 first)"); return; }
  PI(@"launch 1 state: %@; files now: %@", st, DirListing());
  PI(@"OnDownloadUpdated events received before this check started: %zu (hasBrowser=0 means item without a CEF browser)", g_dl_events.size());
  for (auto& e : g_dl_events) PI(@"  early event %s", DlStr(e).c_str());
  int t = AddTab(h, @"chrome://downloads", false);
  Later(6, [=] {
    static NSString* deep = @"(function(){function t(n){let s='';if(n.shadowRoot)s+=t(n.shadowRoot);for(const c of n.childNodes){if(c.nodeType===3)s+=c.textContent+' ';else if(c.nodeType===1&&!['STYLE','SCRIPT'].includes(c.tagName))s+=t(c);}return s;}return t(document.body||document).replace(/\\s+/g,' ').trim().slice(0,600);})()";
    Eval(h, t, deep, false, [=](NSString* txt) {
      PI(@"chrome://downloads text after launch (what the download manager holds): %@", txt);
      PI(@"OnDownloadUpdated events so far: %zu; callbacks held: %zu", g_dl_events.size(), g_dl_cbs.size());
      const unsigned long long b0 = DirBytes();
      bool haveCb = !g_dl_cbs.empty();
      if (haveCb) { auto last = g_dl_events.back(); PI(@"last event %s; calling Resume() on the replayed item's callback", DlStr(last).c_str()); g_dl_cbs.begin()->second->Resume(); }
      // Also try the page's own Resume control (a click inside the downloads WebUI).
      static NSString* click = @"(function(){let n=0;function w(r){for(const e of r.querySelectorAll('*')){if(e.shadowRoot)w(e.shadowRoot);if((e.tagName==='CR-BUTTON'||e.tagName==='BUTTON'||e.tagName==='A')&&/^Resume$/.test((e.textContent||'').trim())&&e.offsetParent!==null){e.click();n++;}}}w(document);return 'clicked '+n;})()";
      Eval(h, t, click, false, [=](NSString* c) {
        PI(@"downloads page Resume click (Retry is not clicked: it starts a new download): %@", c);
        Later(6, [=] {
          const unsigned long long b1 = DirBytes();
          PI(@"after Resume attempts: dir bytes %llu -> %llu (grew=%d); files: %@; events now %zu", b0, b1, (int)(b1 > b0), DirListing(), g_dl_events.size());
          if (!g_dl_events.empty()) PI(@"last event %s", DlStr(g_dl_events.back()).c_str());
          for (auto& kv : g_dl_cbs) kv.second->Cancel();
          // Cleanup: cancel anything the page's Resume brought back, so the next launch starts without a running download.
          Eval(h, t, @"(function(){let n=0;function w(r){for(const e of r.querySelectorAll('*')){if(e.shadowRoot)w(e.shadowRoot);if((e.tagName==='CR-BUTTON'||e.tagName==='BUTTON'||e.tagName==='A')&&/^Cancel$/.test((e.textContent||'').trim())&&e.offsetParent!==null){e.click();n++;}}}w(document);return 'cancel clicked '+n;})()", false, [=](NSString* c2) { PI(@"cleanup: %@", c2); });
          Later(1.5, [=] { Done(h, true, @"launch 2: replay facts recorded, download cancelled for cleanup"); });
        });
      });
    });
  });
}

// ---- R7 ----
void DownloadTabClose(H h) {
  if (!SlowUrl() || DlDir().empty()) { Done(h, false, @"NOCHE_PROBE_SLOW_URL / NOCHE_PROBE_DL_DIR not set (run through probe-engine.sh)"); return; }
  int t2 = AddTab(h, h->url(), false);
  if (t2 < 0) { Done(h, false, @"AddTab returned NULL"); return; }
  WaitFor(h, 10000, [=] { return g_load.count(t2) > 0; }, [=](bool) {
    Eval(h, t2, [NSString stringWithFormat:@"location.href = '%s'; 'go'", SlowUrl()], false, [=](NSString*) {});
    WaitFor(h, 30000, [=] { return !g_dl_events.empty() && g_dl_events.back().recv > 1000000; }, [=](bool started) {
      if (!started) { Done(h, false, @"download in tab 2 never started"); return; }
      const uint32_t id = g_dl_events.back().id;
      PI(@"download started in tab %d: %s", t2, DlStr(g_dl_events.back()).c_str());
      const unsigned long long c0 = DirBytes();
      Later(2.5, [=] {
      PI(@"positive control, tab still open: dir bytes %llu -> %llu over 2.5 s (growing=%d); files %@; events=%zu last: %s", c0, DirBytes(), (int)(DirBytes() > c0), DirListing(), g_dl_events.size(), DlStr(g_dl_events.back()).c_str());
      const size_t ev0 = g_dl_events.size();
      const int tdl = AddTab(h, @"chrome://downloads", false);
      Later(3, [=] {
      Eval(h, tdl, DeepJs(), false, [=](NSString* txt) { PI(@"chrome://downloads before close: %@", txt); });
      if (auto b = ById(h, t2)) b->GetHost()->CloseBrowser(true);
      Later(3, [=] {
      Eval(h, tdl, DeepJs(), false, [=](NSString* txt) { PI(@"chrome://downloads 3 s after close: %@", txt); });
        const size_t ev1 = g_dl_events.size();
        const bool alive = ById(h, t2) != nullptr;
        PI(@"tab %d closed (still listed=%d); OnDownloadUpdated events during the 3 s after close: %zu; last: %s", t2, (int)alive, ev1 - ev0, DlStr(g_dl_events.back()).c_str());
        const unsigned long long s0 = DirBytes();
        Later(2, [=] {
          const unsigned long long s1 = DirBytes();
          PI(@"after close, no Pause: dir bytes %llu -> %llu (download continues: %d); files %@", s0, s1, (int)(s1 > s0), DirListing());
          if (!g_dl_cbs.count(id)) { Done(h, false, @"no callback saved"); return; }
          g_dl_cbs[id]->Pause();
          Later(2, [=] {
            const unsigned long long p0 = DirBytes();
            Later(3, [=] {
              const unsigned long long p1 = DirBytes();
              PI(@"after Pause() through the saved callback: dir bytes %llu -> %llu over 3 s (stopped=%d); events=%zu last: %s", p0, p1, (int)(p1 == p0), g_dl_events.size(), DlStr(g_dl_events.back()).c_str());
              g_dl_cbs[id]->Resume();
              Later(2, [=] {
                const unsigned long long r0 = DirBytes();
                Later(4, [=] {
                  const unsigned long long r1 = DirBytes();
                  PI(@"after Resume() through the saved callback: dir bytes %llu -> %llu over 4 s (growing=%d); events=%zu last: %s files %@", r0, r1, (int)(r1 > r0), g_dl_events.size(), DlStr(g_dl_events.back()).c_str(), DirListing());
                  g_dl_cbs[id]->Cancel();
                  Eval(h, tdl, DeepJs(), false, [=](NSString* txt) { PI(@"chrome://downloads at the end: %@", txt); });
                  Later(1, [=] { Done(h, true, @"tab-close download facts recorded; download cancelled for cleanup"); });
                });
              });
            });
          });
        });
      });
      });
      });
    });
  });
}

// ---- R12 ----
void DumpMenu(CefRefPtr<CefMenuModel> m, int depth, int* extId, std::string* extLabel) {
  for (size_t i = 0; i < m->GetCount(); i++) {
    const int id = m->GetCommandIdAt(i);
    const std::string label = m->GetLabelAt(i).ToString();
    PI(@"menu item depth=%d idx=%zu id=%d type=%d label=\"%@\" enabled=%d visible=%d checked=%d", depth, i, id, (int)m->GetTypeAt(i), @(label.c_str()), (int)m->IsEnabledAt(i), (int)m->IsVisibleAt(i), (int)m->IsCheckedAt(i));
    if (label.find("Noche probe item") != std::string::npos && *extId < 0) { *extId = id; *extLabel = label; }
    if (auto s = m->GetSubMenuAt(i)) DumpMenu(s, depth + 1, extId, extLabel);
  }
}
void CheckCtx(H h) {
  int t = AddTab(h, Page(h, @"/?ctxtab"), true);
  if (t < 0) { Done(h, false, @"AddTab returned NULL"); return; }
  auto gotMenu = std::make_shared<bool>(false);
  auto extId = std::make_shared<int>(-1);
  g_ctx_hook = [=](CefRefPtr<CefMenuModel> m, CefRefPtr<CefRunContextMenuCallback> cb) {
    *gotMenu = true;
    std::string label;
    int id = -1;
    PI(@"model count=%zu", m->GetCount());
    DumpMenu(m, 0, &id, &label);
    *extId = id;
    // Only the callback and the id outlive this call (the model must not).
    dispatch_async(dispatch_get_main_queue(), ^{
      if (id < 0) { PI(@"no item labelled 'Noche probe item' in the model: Cancel()"); cb->Cancel(); }
      else { PI(@"Continue(%d, EVENTFLAG_NONE) for the extension item \"%@\"", id, @(label.c_str())); cb->Continue(id, EVENTFLAG_NONE); }
    });
  };
  WaitFor(h, 15000, [=] { return g_load.count(t) > 0 && ActiveId(h) == t; }, [=](bool) {
    auto fire = [=](int attempt) {
      for (NSString* type in @[ @"mouseMoved", @"mousePressed", @"mouseReleased" ])
        h->cdp(ById(h, t), @"Input.dispatchMouseEvent", @{@"type" : type, @"x" : @120, @"y" : @120, @"button" : [type isEqualToString:@"mouseMoved"] ? @"none" : @"right", @"buttons" : [type isEqualToString:@"mousePressed"] ? @2 : @0, @"clickCount" : [type isEqualToString:@"mouseMoved"] ? @0 : @1}, nullptr);
      PI(@"right click sent (attempt %d)", attempt);
    };
    fire(1);
    WaitFor(h, 8000, [=] { return *gotMenu; }, [=](bool got) {
      if (!got) fire(2);
      WaitFor(h, got ? 0 : 8000, [=] { return *gotMenu; }, [=](bool got2) {
        if (!*gotMenu) { Done(h, false, @"RunContextMenu never called after two CDP right clicks"); return; }
        Later(3, [=] {
          h->extCmd(@{@"what" : @"ctx"}, [=](NSDictionary* j) {
            PI(@"service worker view: %@", [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] encoding:NSUTF8StringEncoding]);
            NSArray* clicks = j[@"clicks"];
            bool match = false;
            if (clicks.count) {
              NSNumber* tid = clicks.lastObject[@"tabId"];
              for (NSDictionary* tab in j[@"tabs"]) if ([tab[@"id"] isEqual:tid] && [tab[@"url"] containsString:@"?ctxtab"]) match = true;
              PI(@"onClicked id=%@ tabId=%@ matches the tab that was right clicked (url has ?ctxtab, CEF browser id %d): %d", clicks.lastObject[@"menuItemId"], tid, t, (int)match);
            } else PI(@"service worker saw no chrome.contextMenus.onClicked (menu item id %d)", *extId);
            Done(h, true, [NSString stringWithFormat:@"context menu model dumped; extension item id=%d; onClicked seen=%d right tab=%d", *extId, (int)(clicks.count > 0), (int)match]);
          });
        });
      });
    });
  });
}

// ---- R13 ----
void CheckZoom(H h) {
  int a = h->first()->GetIdentifier();
  int b = AddTab(h, h->url(), false), c = AddTab(h, Localhost(h->url()), false);
  if (b < 0 || c < 0) { Done(h, false, @"AddTab returned NULL"); return; }
  WaitFor(h, 15000, [=] { return g_load.count(b) && g_load.count(c); }, [=](bool) {
    auto zoom = [=](const char* when) {
      NSMutableArray* o = [NSMutableArray array];
      for (int id : TabIds(h)) if (auto br = ById(h, id)) [o addObject:[NSString stringWithFormat:@"tab%d(%s)=%.3f", id, br->GetMainFrame()->GetURL().ToString().find("localhost") != std::string::npos ? "localhost" : "127.0.0.1", br->GetHost()->GetZoomLevel()]];
      PI(@"zoom %s: %@", when, [o componentsJoinedByString:@" "]);
    };
    zoom("initial");
    ById(h, a)->GetHost()->SetZoomLevel(1.0);
    Later(1.5, [=] {
      zoom("after tab A SetZoomLevel(1.0)");
      h->view()->SetActiveTab(ById(h, a));
      ById(h, a)->GetHost()->ExecuteChromeCommand(cef_id_for_command_id_name("IDC_ZOOM_PLUS"), CEF_WOD_CURRENT_TAB);
      Later(1.5, [=] {
        zoom("after tab A IDC_ZOOM_PLUS");
        h->view()->SetActiveTab(ById(h, b));
        ById(h, b)->GetHost()->ExecuteChromeCommand(cef_id_for_command_id_name("IDC_ZOOM_PLUS"), CEF_WOD_CURRENT_TAB);
        Later(1.5, [=] {
          zoom("after tab B IDC_ZOOM_PLUS");
          int d = AddTab(h, h->url(), false);
          WaitFor(h, 10000, [=] { return g_load.count(d) > 0; }, [=](bool) {
            zoom("new tab D opened on the same host afterwards");
            ById(h, a)->GetHost()->SetZoomLevel(0);
            Later(1, [=] { zoom("reset via tab A SetZoomLevel(0)"); Done(h, true, @"zoom scope facts recorded"); });
          });
        });
      });
    });
  });
}

// ---- R14 ----
void CheckChromePages(H h) {
  auto urls = @[ @"chrome://history", @"chrome://downloads", @"chrome://bookmarks" ];
  auto ids = std::make_shared<std::vector<int>>();
  for (NSString* u in urls) { int id = AddTab(h, u, false); ids->push_back(id); PI(@"AddTab %@ -> tab id %d", u, id); }
  WaitFor(h, 20000, [=] { for (int id : *ids) if (id >= 0 && !g_load.count(id)) return false; return true; }, [=](bool) {
    Later(3, [=] {
      static NSString* js = @"(function(){function t(n){let s='';if(n.shadowRoot)s+=t(n.shadowRoot);for(const c of n.childNodes){if(c.nodeType===3)s+=c.textContent+' ';else if(c.nodeType===1&&!['STYLE','SCRIPT'].includes(c.tagName))s+=t(c);}return s;}const d=t(document.body||document).replace(/\\s+/g,' ').trim();return JSON.stringify({url:location.href,title:document.title,innerText:document.body?document.body.innerText.length:-1,deepText:d.length,sample:d.slice(0,120)});})()";
      auto step = std::make_shared<std::function<void(size_t)>>();
      *step = [=](size_t i) {
        if (i == ids->size()) { H hh = h; *step = nullptr; Done(hh, true, @"3 chrome:// pages opened as tabs, facts above"); return; }
        const int id = (*ids)[i];
        if (id < 0) { PI(@"%@: AddTab returned NULL", urls[i]); (*step)(i + 1); return; }
        auto br = ById(h, id);
        PI(@"%@: tab %d loadEndStatus=%d mainFrameUrl=%s", urls[i], id, g_load.count(id) ? g_load[id] : -1, br ? br->GetMainFrame()->GetURL().ToString().c_str() : "(gone)");
        Eval(h, id, js, false, [=](NSString* r) { PI(@"%@: Runtime.evaluate -> %@", urls[i], r.length ? r : @"(no value)"); (*step)(i + 1); });
      };
      (*step)(0);
    });
  });
}

}  // namespace

void SurfEarly(NSString* check) {
  g_t0 = NowMs();
  g_dl_on = [check hasPrefix:@"download-"];
  g_perm_on = [check isEqualToString:@"bubbles"] ? false : false;  // bubbles switches the handler on for phase 2
  g_ctx_on = [check isEqualToString:@"ctx-ext-items"];
  g_name = check;
  g_dl = new DlHandler();
  g_perm = new PermHandler();
  g_ctx = new CtxHandler();
}
CefRefPtr<CefContextMenuHandler> SurfContextMenuHandler() { return g_ctx_on ? CefRefPtr<CefContextMenuHandler>(g_ctx) : nullptr; }
CefRefPtr<CefDownloadHandler> SurfDownloadHandler() { return g_dl_on ? CefRefPtr<CefDownloadHandler>(g_dl) : nullptr; }
CefRefPtr<CefPermissionHandler> SurfPermissionHandler() { return g_perm_on ? CefRefPtr<CefPermissionHandler>(g_perm) : nullptr; }
void SurfOnLoadEnd(int id, int status) { g_load[id] = status; }

bool RunSurfacesCheck(NSString* check, const SurfHost& host) {
  static NSDictionary* table = @{
    @"cmd-enabled" : @0, @"bubbles" : @1, @"download-restart-1" : @2, @"download-restart-2" : @3, @"download-tab-close" : @4,
    @"ctx-ext-items" : @5, @"zoom-scope" : @6, @"chrome-pages" : @7 };
  NSNumber* n = table[check];
  if (!n) return false;
  g_name = check;
  H h = std::make_shared<const SurfHost>(host);
  switch (n.intValue) {
    case 0: CheckCmdEnabled(h); break;
    case 1: CheckBubbles(h); break;
    case 2: DownloadRestart1(h); break;
    case 3: DownloadRestart2(h); break;
    case 4: DownloadTabClose(h); break;
    case 5: CheckCtx(h); break;
    case 6: CheckZoom(h); break;
    default: CheckChromePages(h); break;
  }
  return true;
}
#endif
