// Surfaces checks: see surfaces.h. Every check prints facts as "PROBE <check> info ..." and passes when the experiment ran.
#import "surfaces.h"
#include "resloads.h"
#include <chrono>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <sys/stat.h>
#include "include/cef_id_mappers.h"
#include "include/cef_command_ids.h"
#include "include/cef_command_line.h"

#ifndef NOCHE_TABS_API
void SurfEarly(NSString*) {}
CefRefPtr<CefContextMenuHandler> SurfContextMenuHandler() { return nullptr; }
CefRefPtr<CefDownloadHandler> SurfDownloadHandler() { return nullptr; }
CefRefPtr<CefPermissionHandler> SurfPermissionHandler() { return nullptr; }
void SurfOnLoadEnd(int, int) {}
bool RunSurfacesCheck(NSString* c, const SurfHost& h) {
  if (![@[ @"cmd-enabled", @"bubbles", @"download-restart-1", @"download-restart-2", @"download-tab-close", @"download-tab-close-start", @"download-keep-stream", @"download-keep-complete", @"download-restart-crash-1", @"download-restart-crash-2", @"download-control-cancel-1", @"download-control-cancel-2", @"download-control-rejected", @"download-control-noprofile", @"ctx-ext-items", @"zoom-scope", @"chrome-pages", @"zoom-no-bubble", @"discard-p1", @"discard-p1b", @"discard-p1b-off", @"discard-p2", @"discard-p3", @"discard-api", @"discard-p5" ] containsObject:c]) return false;
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
// A download whose file lands outside NOCHE_PROBE_DL_DIR is cancelled at once (the engine then deletes its partial) and fails the check in Done().
std::string g_dl_escape;
NSString* RealPath(const std::string& p) { return [@(p.c_str()) stringByResolvingSymlinksInPath]; }
bool InsideDlDir(const std::string& path) {
  if (DlDir().empty() || path.empty()) return true;
  return [RealPath(path) hasPrefix:[RealPath(DlDir()) stringByAppendingString:@"/"]];
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
    // Only live items: finished or cancelled rows replayed from History keep the temp dir of an earlier run.
    if (!e.complete && !e.canceled && !InsideDlDir(e.path)) {
      if (g_dl_escape.empty()) g_dl_escape = "download id " + std::to_string(e.id) + " targeted " + e.path + " outside NOCHE_PROBE_DL_DIR " + DlDir() + ", cancelled by the probe";
      if (cb) cb->Cancel();
    }
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
  if (!g_dl_escape.empty()) { ok = false; d = [NSString stringWithFormat:@"%s; %@", g_dl_escape.c_str(), d]; }
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
// ---- M1.5 downloads (engine patch 0008): R6 restart, R7 tab close, negative controls ----
// Independent witnesses, not the app and not the engine: the server's request log (Range headers), the SHA-256 of the
// downloaded bytes against the server's deterministic pattern, the History database (read by the script between launches).
// Every check records named assertions; a check passes only if all of them hold. RED on an engine without patch 0008.
#ifdef NOCHE_DOWNLOAD_API
constexpr bool kProfileApi = true;
#else
constexpr bool kProfileApi = false;  // engine without CefRequestContext::SetDownloadHandler
#endif
constexpr unsigned long long kMid = 24ull * 1024 * 1024;
size_t g_log0 = 0;  // length of the server's request log when this launch started

NSString* StateFile() { return [(getenv("NOCHE_PROBE_ROOT") ? @(getenv("NOCHE_PROBE_ROOT")) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Probe"]) stringByAppendingPathComponent:@"download-restart.state"]; }
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
const char* MidUrl() { return getenv("NOCHE_PROBE_MID_URL"); }
bool DlEnv(H h) {
  if (MidUrl() && SlowUrl() && getenv("NOCHE_PROBE_SLOW_LOG") && !DlDir().empty()) return true;
  h->finish(false, @"NOCHE_PROBE_MID_URL / NOCHE_PROBE_SLOW_LOG / NOCHE_PROBE_DL_DIR not set (run through probe-engine.sh)");
  return false;
}
NSString* ServerLog() { return [NSString stringWithContentsOfFile:@(getenv("NOCHE_PROBE_SLOW_LOG") ?: "/dev/null") encoding:NSUTF8StringEncoding error:nil] ?: @""; }
NSString* ServerLogSinceStart() { NSString* l = ServerLog(); return l.length > g_log0 ? [l substringFromIndex:g_log0] : @""; }
NSString* MidPath() { return [@(DlDir().c_str()) stringByAppendingPathComponent:@"mid.bin"]; }
unsigned long long FileSize(NSString* p) { return [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil].fileSize; }
NSString* Hex(const unsigned char* d) {
  NSMutableString* s = [NSMutableString string];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", d[i]];
  return s;
}
// SHA-256 of the first n bytes of the server's pattern (byte i = (i * 31 + 7) mod 251).
NSString* PatternSha(unsigned long long n) {
  CC_SHA256_CTX c; CC_SHA256_Init(&c);
  std::vector<unsigned char> buf(1 << 20);
  for (unsigned long long off = 0; off < n;) {
    size_t k = (size_t)std::min<unsigned long long>(buf.size(), n - off);
    for (size_t i = 0; i < k; i++) buf[i] = (unsigned char)(((off + i) * 31 + 7) % 251);
    CC_SHA256_Update(&c, buf.data(), (CC_LONG)k);
    off += k;
  }
  unsigned char d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(d, &c);
  return Hex(d);
}
// SHA-256 of the first n bytes of the file at p, or @"" if it is shorter or unreadable.
NSString* FileSha(NSString* p, unsigned long long n) {
  NSFileHandle* f = [NSFileHandle fileHandleForReadingAtPath:p];
  if (!f) return @"";
  CC_SHA256_CTX c; CC_SHA256_Init(&c);
  unsigned long long left = n;
  while (left) {
    NSData* d = [f readDataOfLength:(NSUInteger)std::min<unsigned long long>(left, 1 << 20)];
    if (!d.length) return @"";
    CC_SHA256_Update(&c, d.bytes, (CC_LONG)d.length);
    left -= d.length;
  }
  unsigned char d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(d, &c);
  return Hex(d);
}

struct Asserts {
  std::vector<std::string> failed;
  void Check(const char* name, bool ok, NSString* detail) {
    if (!ok) failed.push_back(name);
    PI(@"assert %s %s: %@", name, ok ? "PASS" : "FAIL", detail);
  }
  void Api(const char* what) {
    Check("profile-handler-api", kProfileApi, kProfileApi ? @"CefRequestContext::SetDownloadHandler compiled in" : [NSString stringWithFormat:@"CefRequestContext::SetDownloadHandler is not in this engine build (NOCHE_DOWNLOAD_API unset): %s cannot be observed through a profile handler", what]);
  }
  bool ok() const { return failed.empty(); }
  NSString* Summary() const {
    if (failed.empty()) return @"every assertion held";
    NSMutableArray* a = [NSMutableArray array];
    for (auto& f : failed) [a addObject:@(f.c_str())];
    return [NSString stringWithFormat:@"%zu assertion(s) failed: %@", failed.size(), [a componentsJoinedByString:@", "]];
  }
};
using AS = std::shared_ptr<Asserts>;
using Next = std::function<void()>;
using Step = std::function<void(Next)>;
using Steps = std::shared_ptr<std::vector<Step>>;
void RunSteps(Steps s, size_t i = 0) {
  if (i < s->size()) (*s)[i]([=] { RunSteps(s, i + 1); });
}
Step Sleep(double sec) { return [=](Next n) { Later(sec, n); }; }

// Events of one download id as seen by the handlers (profile handler events have browser=0).
size_t EventsFor(uint32_t id, size_t from, bool (*pred)(const DlEv&)) {
  size_t n = 0;
  for (size_t i = from; i < g_dl_events.size(); i++) if (g_dl_events[i].id == id && pred(g_dl_events[i])) n++;
  return n;
}
bool NoBrowserInProgress(const DlEv& e) { return !e.hasBrowser && e.inprog; }
bool NoBrowser(const DlEv& e) { return !e.hasBrowser; }
bool AnyInProgress(const DlEv& e) { return e.inprog; }
const DlEv* FirstNoBrowserEvent(uint32_t id) {
  for (auto& e : g_dl_events) if (e.id == id && !e.hasBrowser) return &e;
  return nullptr;
}
// Status word after "mid.bin mid.bin" in the chrome://downloads text ("Canceled" for a canceled row).
NSString* RowStatus(NSString* txt, NSString* name) {
  NSString* pat = [NSString stringWithFormat:@"%@ %@ (\\S+)", [NSRegularExpression escapedPatternForString:name], [NSRegularExpression escapedPatternForString:name]];
  NSTextCheckingResult* m = [[NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil] firstMatchInString:txt options:0 range:NSMakeRange(0, txt.length)];
  return m ? [txt substringWithRange:[m rangeAtIndex:1]] : nil;
}
// Reads chrome://downloads (opened as a tab) and hands its text to |cb|.
void DownloadsPageText(H h, std::function<void(NSString*)> cb) {
  const int t = AddTab(h, @"chrome://downloads", false);
  WaitFor(h, 10000, [=] { return g_load.count(t) > 0; }, [=](bool) {
    Later(2, [=] { Eval(h, t, DeepJs(), false, [=](NSString* txt) { cb(txt ?: @""); }); });
  });
}
void StartMidInFirstTab(H h) {
  h->eval(h->first(), [NSString stringWithFormat:@"location.href = '%s'; 'go'", MidUrl()], false, [](NSString*) {});
}
bool DlEventsPaused() { for (auto& e : g_dl_events) if (e.paused) return true; return false; }

// ---- R7: download survives its tab ----
// Variant 1 starts the download by navigating tab 2 to the file, variant 2 with CefBrowserHost::StartDownload from tab 2. Either way the
// tab is then closed: the partial file must keep growing, the profile handler must be told (browser=0), Pause and Resume through the
// saved callback must work, and the download must complete with the pattern's SHA-256.
void DownloadTabClose(H h, bool viaStartDownload) {
  if (!DlEnv(h)) return;
  auto A = std::make_shared<Asserts>();
  auto id = std::make_shared<uint32_t>(0);
  auto t2 = std::make_shared<int>(-1);
  auto c0 = std::make_shared<unsigned long long>(0), p0 = std::make_shared<unsigned long long>(0), p1 = std::make_shared<unsigned long long>(0);
  auto ev0 = std::make_shared<size_t>(0);
  auto S = std::make_shared<std::vector<Step>>();
  S->push_back([=](Next n) {
    A->Api("events for a download whose tab is gone");
    *t2 = AddTab(h, h->url(), false);
    if (*t2 < 0) { Done(h, false, @"AddTab returned NULL"); return; }
    WaitFor(h, 10000, [=] { return g_load.count(*t2) > 0; }, [=](bool) { n(); });
  });
  S->push_back([=](Next n) {
    if (viaStartDownload) ById(h, *t2)->GetHost()->StartDownload(MidUrl());
    else Eval(h, *t2, [NSString stringWithFormat:@"location.href = '%s'; 'go'", MidUrl()], false, [](NSString*) {});
    WaitFor(h, 30000, [=] { return !g_dl_events.empty() && g_dl_events.back().inprog && g_dl_events.back().recv > 1000000; }, [=](bool started) {  // inprog: a profile with older downloads replays them first
      if (!started) { Done(h, false, @"download never started in tab 2"); return; }
      *id = g_dl_events.back().id;
      PI(@"download started (%s): %s", viaStartDownload ? "StartDownload" : "navigation", DlStr(g_dl_events.back()).c_str());
      *c0 = DirBytes();
      n();
    });
  });
  S->push_back(Sleep(2.0));
  S->push_back([=](Next n) {
    A->Check("control-open-tab-grows", DirBytes() > *c0 + 500000, [NSString stringWithFormat:@"tab still open: dir bytes %llu -> %llu over 2 s", *c0, DirBytes()]);
    if (auto b = ById(h, *t2)) b->GetHost()->CloseBrowser(true);
    WaitFor(h, 10000, [=] { return ById(h, *t2) == nullptr; }, [=](bool gone) {
      Later(0.5, [=] {
        *c0 = DirBytes(); *ev0 = g_dl_events.size();
        PI(@"tab %d closed (gone=%d); dir bytes %llu; events so far %zu; last: %s", *t2, (int)gone, *c0, *ev0, DlStr(g_dl_events.back()).c_str());
        n();
      });
    });
  });
  S->push_back(Sleep(2.5));
  S->push_back([=](Next n) {
    A->Check("a-partial-grows-after-close", DirBytes() > *c0 + 1000000, [NSString stringWithFormat:@"dir bytes %llu -> %llu over 2.5 s after the tab was gone; files %@", *c0, DirBytes(), DirListing()]);
    size_t k = EventsFor(*id, *ev0, NoBrowserInProgress);
    A->Check("b-profile-handler-events-without-browser", k > 0, [NSString stringWithFormat:@"%zu in-progress OnDownloadUpdated events with browser=0 for id %u after close (all events after close: %zu)", k, *id, g_dl_events.size() - *ev0]);
    n();
  });
  S->push_back([=](Next n) {
    if (!g_dl_cbs.count(*id)) { A->Check("c-pause-resume", false, @"no callback saved"); n(); return; }
    g_dl_cbs[*id]->Pause();
    Later(2.0, [=] { *p0 = DirBytes(); Later(2.5, [=] { *p1 = DirBytes(); n(); }); });
  });
  S->push_back([=](Next n) {
    A->Check("c1-pause-stops-growth", *p0 > 0 && *p1 == *p0, [NSString stringWithFormat:@"after Pause(): dir bytes %llu -> %llu over 2.5 s (want a non-empty partial that stopped growing)", *p0, *p1]);
    if (g_dl_cbs.count(*id)) g_dl_cbs[*id]->Resume();
    Later(3.0, [=] {
      A->Check("c2-resume-restarts-growth", DirBytes() > *p1 + 500000, [NSString stringWithFormat:@"after Resume(): dir bytes %llu -> %llu over 3 s", *p1, DirBytes()]);
      n();
    });
  });
  S->push_back([=](Next n) {
    WaitFor(h, 40000, [=] { return FileSize(MidPath()) == kMid && !g_dl_events.empty() && g_dl_events.back().complete; }, [=](bool done) {
      A->Check("d1-completes-within-40s", done, [NSString stringWithFormat:@"files %@; last event: %s", DirListing(), g_dl_events.empty() ? "(none)" : DlStr(g_dl_events.back()).c_str()]);
      NSString* got = done ? FileSha(MidPath(), kMid) : @"";
      NSString* want = PatternSha(kMid);
      A->Check("d2-sha256-equals-pattern", [got isEqualToString:want], [NSString stringWithFormat:@"file %@ expected %@", got.length ? got : @"(unreadable or short)", want]);
      n();
    });
  });
  S->push_back([=](Next n) {
    DownloadsPageText(h, [=](NSString* txt) {
      NSString* st = RowStatus(txt, @"mid.bin");
      A->Check("e-downloads-page-not-canceled", st && ![st isEqualToString:@"Canceled"], [NSString stringWithFormat:@"chrome://downloads row mid.bin status word: %@", st ?: @"(no row)"]);
      n();
    });
  });
  S->push_back([=](Next) {
    if (g_dl_cbs.count(*id) && !(g_dl_events.size() && g_dl_events.back().complete)) g_dl_cbs[*id]->Cancel();  // cleanup
    Done(h, A->ok(), [NSString stringWithFormat:@"tab-close download (%s): %@", viaStartDownload ? "StartDownload variant" : "navigation variant", A->Summary()]);
  });
  RunSteps(S);
}

// ---- 0008 kept-request contract (review E15) ----
// The keep rule is "the response arrived", not "is a download", so two controls pair up. A tab on /hold.html (a text/html stream that never ends) is closed
// after its first bytes: the request must NOT outlive the tab (the server sees the connection close) and the client's OnResourceLoadComplete runs at most once.
// A tab whose navigation became a download is closed: the request is kept, its single completion arrives after the download finished, with the original
// browser (IsValid() false by then). Both read the server's request log and a per-tab RlRecorder, not the engine's own reports.
NSString* Token() { return [NSString stringWithFormat:@"%llx", (unsigned long long)(arc4random() | ((uint64_t)arc4random() << 32))]; }
bool LogHas(NSString* needle) { return [ServerLogSinceStart() containsString:needle]; }
NSString* RecFacts(const std::vector<RlRec>& v) {
  NSMutableArray* o = [NSMutableArray array];
  for (auto& r : v) [o addObject:[NSString stringWithFormat:@"browser=%d status=%d valid=%d", r.browserId, r.status, (int)(r.browser && r.browser->IsValid())]];
  return o.count ? [o componentsJoinedByString:@"; "] : @"(none)";
}
void KeepStream(H h) {
  if (!DlEnv(h)) return;
  auto A = std::make_shared<Asserts>();
  auto rec = CefRefPtr<RlRecorder>(new RlRecorder());
  rec->keepNeedle = "hold.html?keep=";
  auto cl = CefRefPtr<RlClient>(new RlClient(rec, nullptr));
  NSString* path = [@"/hold.html?keep=" stringByAppendingString:Token()];
  NSString* url = [[@(SlowUrl()) stringByReplacingOccurrencesOfString:@"/big.bin" withString:@""] stringByAppendingString:path];
  auto id = std::make_shared<int>(-1);
  auto closedAt = std::make_shared<double>(0);
  auto S = std::make_shared<std::vector<Step>>();
  S->push_back([=](Next n) {
    auto v = h->view();
    auto b = v ? v->AddTab(url.UTF8String, cl, CefBrowserSettings(), nullptr, false) : nullptr;
    if (!b) { Done(h, false, @"AddTab returned NULL"); return; }
    *id = b->GetIdentifier();
    WaitFor(h, 15000, [=] { return LogHas(@"hold.html"); }, [=](bool reached) {
      A->Check("a-request-reached-server", reached, [NSString stringWithFormat:@"tab %d asked the fixture server for %@", *id, path]);
      n();
    });
  });
  S->push_back(Sleep(1.5));
  S->push_back([=](Next n) {
    Eval(h, *id, @"document.title + '|' + document.readyState", false, [=](NSString* r) {
      auto b = ById(h, *id);
      A->Check("b-first-bytes-arrived-and-stream-open", [r hasPrefix:@"hold|"] && ![r hasSuffix:@"|complete"] && b && b->IsLoading(), [NSString stringWithFormat:@"title|readyState '%@', IsLoading=%d (the document started and the response is still open)", r, b ? (int)b->IsLoading() : -1]);
      *closedAt = NowMs();
      if (b) b->GetHost()->CloseBrowser(true);
      n();
    });
  });
  S->push_back([=](Next n) {
    NSString* line = [@"closed " stringByAppendingString:path];
    WaitFor(h, 5000, [=] { return LogHas(line); }, [=](bool closed) {
      A->Check("c-server-sees-connection-closed-within-5s", closed, [NSString stringWithFormat:@"server log line '%@' %@ %.0f ms after CloseBrowser (limit 5000)", line, closed ? @"appeared" : @"did NOT appear within 5 s;", NowMs() - *closedAt]);
      n();
    });
  });
  S->push_back(Sleep(2.0));
  S->push_back([=](Next) {
    auto recs = rec->Recs("hold.html?keep=");
    A->Check("d-on-resource-load-complete-at-most-once", recs.size() <= 1, [NSString stringWithFormat:@"%zu OnResourceLoadComplete for the held request (want <= 1): %@", recs.size(), RecFacts(recs)]);
    A->Check("e-tab-gone", ById(h, *id) == nullptr, @"the closed tab is no longer listed");
    NSString* sum = A->Summary();
    rec->Clear();
    Done(h, A->ok(), [NSString stringWithFormat:@"kept-request contract, non-download stream: %@", sum]);
  });
  RunSteps(S);
}

void KeepComplete(H h) {
  if (!DlEnv(h)) return;
  auto A = std::make_shared<Asserts>();
  auto rec = CefRefPtr<RlRecorder>(new RlRecorder());
  rec->keepNeedle = "mid.bin";
  auto cl = CefRefPtr<RlClient>(new RlClient(rec, CefRefPtr<CefDownloadHandler>(g_dl)));
  auto id = std::make_shared<int>(-1);
  auto early = std::make_shared<bool>(false);
  auto S = std::make_shared<std::vector<Step>>();
  S->push_back([=](Next n) {
    A->Api("a kept download whose tab is gone");
    auto v = h->view();
    auto b = v ? v->AddTab(MidUrl(), cl, CefBrowserSettings(), nullptr, false) : nullptr;  // the navigation becomes the download
    if (!b) { Done(h, false, @"AddTab returned NULL"); return; }
    *id = b->GetIdentifier();
    WaitFor(h, 30000, [=] { return !g_dl_events.empty() && g_dl_events.back().inprog && g_dl_events.back().recv > 1000000; }, [=](bool started) {
      if (!started) { Done(h, false, @"download never started in the tab"); return; }
      PI(@"download started from tab %d: %s", *id, DlStr(g_dl_events.back()).c_str());
      if (auto t = ById(h, *id)) t->GetHost()->CloseBrowser(true);
      n();
    });
  });
  S->push_back(Sleep(3.0));
  S->push_back([=](Next n) {
    auto r = rec->Recs("mid.bin");
    A->Check("a-no-completion-while-download-runs", r.empty() && FileSize(MidPath()) < kMid, [NSString stringWithFormat:@"3 s after the tab closed: %zu OnResourceLoadComplete for mid.bin (want 0, the kept request is not reported as aborted), file %llu of %llu bytes", r.size(), FileSize(MidPath()), kMid]);
    WaitFor(h, 40000, [=] { if (FileSize(MidPath()) < kMid && !rec->Recs("mid.bin").empty()) *early = true; return FileSize(MidPath()) == kMid && !g_dl_events.empty() && g_dl_events.back().complete; }, [=](bool done) {
      A->Check("b-download-completes", done, [NSString stringWithFormat:@"files %@; last event: %s", DirListing(), g_dl_events.empty() ? "(none)" : DlStr(g_dl_events.back()).c_str()]);
      n();
    });
  });
  S->push_back(Sleep(2.5));
  S->push_back([=](Next) {
    auto r = rec->Recs("mid.bin");
    A->Check("c-exactly-one-completion", r.size() == 1, [NSString stringWithFormat:@"%zu OnResourceLoadComplete for mid.bin after the download finished (want 1): %@", r.size(), RecFacts(r)]);
    A->Check("d-completion-only-after-the-bytes-arrived", !*early, @"no completion was seen at any 100 ms sample while the file was still short");
    A->Check("e-original-browser-and-invalid", r.size() == 1 && r[0].browserId == *id && r[0].browser && !r[0].browser->IsValid(), [NSString stringWithFormat:@"completion browser id %d (want %d), IsValid=%d (want 0)", r.empty() ? -1 : r[0].browserId, *id, r.empty() || !r[0].browser ? -1 : (int)r[0].browser->IsValid()]);
    NSString* sum = A->Summary();
    rec->Clear();  // drops the CefBrowser references the records hold: a browser still referenced at shutdown aborts the engine
    Done(h, A->ok(), [NSString stringWithFormat:@"kept-request contract, kept download: %@", sum]);
  });
  RunSteps(S);
}

// ---- R6: restart ----
// Launch 1 starts the download, pauses it at 10 percent and records what is on disk. With crash=false it then quits normally (the paused
// download is interrupted at shutdown with patch 0008); with crash=true it prints ready-to-kill and waits for the script's kill -9.
void DownloadRestart1(H h, bool crash) {
  if (!DlEnv(h)) return;
  auto A = std::make_shared<Asserts>();
  auto paused = std::make_shared<bool>(false);
  g_dl_hook = [=](const DlEv& e) {
    if (!*paused && e.inprog && e.pct >= 10) {
      *paused = true;
      PI(@"pausing at pct=%d recv=%lld", e.pct, (long long)e.recv);
      g_dl_cbs[e.id]->Pause();
    }
  };
  StartMidInFirstTab(h);
  WaitFor(h, 40000, [=] { return DlEventsPaused(); }, [=](bool ok) {
    if (!ok) { Done(h, false, @"download never reached 10 percent and a paused state in 40 s"); return; }
    Later(crash ? 14.0 : 2.5, [=] {  // crash: let the History database commit the paused row before the kill
      DlEv last = g_dl_events.back();
      NSString* path = @(last.path.c_str());
      PI(@"before %s: %s files: %@", crash ? "kill -9" : "quit", DlStr(last).c_str(), DirListing());
      NSString* want = PatternSha(last.recv);
      NSString* got = FileSha(path, last.recv);
      A->Check("prefix-on-disk-matches-pattern", got.length && [got isEqualToString:want], [NSString stringWithFormat:@"first %lld bytes of the partial: sha %@ pattern %@", (long long)last.recv, got.length ? got : @"(short or unreadable)", want]);
      NSString* st = [NSString stringWithFormat:@"id=%u\nrecv=%lld\ntotal=%lld\npath=%@\nsha=%@\n", last.id, (long long)last.recv, (long long)last.total, path, got];
      [st writeToFile:StateFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
      if (!crash) { Done(h, A->ok(), [NSString stringWithFormat:@"launch 1: paused download recorded (id=%u recv=%lld), quitting with it paused; %@", last.id, (long long)last.recv, A->Summary()]); return; }
      PI(@"ready-to-kill");  // the script sees this line and sends SIGKILL; nothing below runs
      Later(60, [=] { Done(h, false, @"ready-to-kill was printed but nobody killed the app"); });
    });
  });
}

bool ReadState(NSString* key, unsigned long long* out, NSString** str) {
  NSString* st = [NSString stringWithContentsOfFile:StateFile() encoding:NSUTF8StringEncoding error:nil];
  for (NSString* line in [st componentsSeparatedByString:@"\n"]) {
    if (![line hasPrefix:[key stringByAppendingString:@"="]]) continue;
    NSString* v = [line substringFromIndex:key.length + 1];
    if (str) *str = v;
    if (out) *out = strtoull(v.UTF8String, nullptr, 10);
    return true;
  }
  return false;
}

// Launch 2 (profile handler set before the first navigation in SurfEarly): the item must replay as interrupted without a browser, keep its
// bytes, resume with a Range request and finish with the pattern's SHA-256.
void DownloadRestart2(H h, bool crash) {
  if (!DlEnv(h)) return;
  unsigned long long id = 0, recv = 0, total = 0; NSString *path = nil, *sha = nil;
  if (!ReadState(@"id", &id, nullptr) || !ReadState(@"recv", &recv, nullptr) || !ReadState(@"total", &total, nullptr) || !ReadState(@"path", nullptr, &path) || !ReadState(@"sha", nullptr, &sha)) { Done(h, false, @"no state file from launch 1 (run the -1 check first, same script run)"); return; }
  auto A = std::make_shared<Asserts>();
  PI(@"launch 1 state: id=%llu recv=%llu total=%llu path=%@ sha=%@; files now: %@", id, recv, total, path, sha, DirListing());
  auto S = std::make_shared<std::vector<Step>>();
  S->push_back([=](Next n) { A->Api("the replay of a restored download"); Later(6, n); });
  S->push_back([=](Next n) {
    PI(@"events received before any resume: %zu", g_dl_events.size());
    for (auto& e : g_dl_events) if (e.id == (uint32_t)id) PI(@"  event %s", DlStr(e).c_str());
    const DlEv* e = FirstNoBrowserEvent((uint32_t)id);
    A->Check("a-replayed-as-interrupted-without-browser", e && e->interrupted && !e->canceled, e ? [NSString stringWithFormat:@"first browser=0 event for id %llu: %s", id, DlStr(*e).c_str()] : [NSString stringWithFormat:@"no browser=0 event for id %llu (profile handler absent or the item was dropped)", id]);
    const unsigned long long sz = FileSize(path);
    NSString* got = sz >= recv ? FileSha(path, recv) : @"";
    A->Check("b-partial-kept-with-matching-prefix", sz >= recv && [got isEqualToString:sha], [NSString stringWithFormat:@"partial %@ size %llu (want >= %llu), prefix sha %@ (want %@)", path, sz, recv, got.length ? got : @"(missing or short)", sha]);
    if (g_dl_cbs.count((uint32_t)id)) { PI(@"calling Resume() on the replayed item's callback"); g_dl_cbs[(uint32_t)id]->Resume(); }
    else A->Check("resume-callback-available", false, @"no OnDownloadUpdated callback for the item, cannot Resume()");
    Later(4, n);
  });
  S->push_back([=](Next n) {
    NSString* log = ServerLogSinceStart();
    long long start = -1;
    for (NSString* line in [log componentsSeparatedByString:@"\n"]) {
      NSRange r = [line rangeOfString:@"/mid.bin range=bytes="];
      if (r.location == NSNotFound) continue;
      start = strtoll([line substringFromIndex:NSMaxRange(r)].UTF8String, nullptr, 10);
    }
    A->Check("c-resume-sent-range-request", start > 0 && (unsigned long long)start <= recv, [NSString stringWithFormat:@"server saw Range start %lld for /mid.bin since this launch began (want 1..%llu); log: %@", start, recv, [log stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]]);
    n();
  });
  S->push_back([=](Next n) {
    WaitFor(h, 40000, [=] { return FileSize(path) == total && FirstNoBrowserEvent((uint32_t)id) && g_dl_events.back().complete; }, [=](bool done) {
      A->Check("d1-completes-within-40s", done, [NSString stringWithFormat:@"files %@; last event: %s", DirListing(), g_dl_events.empty() ? "(none)" : DlStr(g_dl_events.back()).c_str()]);
      NSString* got = done ? FileSha(path, total) : @"";
      NSString* want = PatternSha(total);
      A->Check("d2-sha256-equals-pattern", [got isEqualToString:want], [NSString stringWithFormat:@"file %@ expected %@", got.length ? got : @"(unreadable or short)", want]);
      n();
    });
  });
  S->push_back([=](Next) {
    if (g_dl_cbs.count((uint32_t)id) && !g_dl_events.back().complete) g_dl_cbs[(uint32_t)id]->Cancel();  // cleanup
    Done(h, A->ok(), [NSString stringWithFormat:@"launch 2 (%s): %@", crash ? "after kill -9" : "after clean quit", A->Summary()]);
  });
  RunSteps(S);
}

// ---- negative controls ----
// A download the client cancelled stays cancelled over a restart: no resume, no file, never in progress again.
void ControlCancel1(H h) {
  if (!DlEnv(h)) return;
  auto canceled = std::make_shared<bool>(false);
  g_dl_hook = [=](const DlEv& e) {
    if (!*canceled && e.inprog && e.pct >= 10) { *canceled = true; PI(@"cancelling at pct=%d recv=%lld through the callback", e.pct, (long long)e.recv); g_dl_cbs[e.id]->Cancel(); }
  };
  StartMidInFirstTab(h);
  WaitFor(h, 40000, [=] { for (auto& e : g_dl_events) if (e.canceled) return true; return false; }, [=](bool ok) {
    if (!ok) { Done(h, false, @"download never reached 10 percent and a canceled state"); return; }
    Later(2.5, [=] {
      DlEv last = g_dl_events.back();
      [[NSString stringWithFormat:@"id=%u\n", last.id] writeToFile:StateFile() atomically:YES encoding:NSUTF8StringEncoding error:nil];
      PI(@"before quit: %s files: %@", DlStr(last).c_str(), DirListing());
      Done(h, last.canceled, [NSString stringWithFormat:@"launch 1: client-cancelled download id=%u recorded (canceled=%d)", last.id, (int)last.canceled]);
    });
  });
}
void ControlCancel2(H h) {
  if (!DlEnv(h)) return;
  unsigned long long id = 0;
  if (!ReadState(@"id", &id, nullptr)) { Done(h, false, @"no state file from launch 1"); return; }
  auto A = std::make_shared<Asserts>();
  auto S = std::make_shared<std::vector<Step>>();
  S->push_back(Sleep(6));
  S->push_back([=](Next n) {
    PI(@"events: %zu; files: %@", g_dl_events.size(), DirListing());
    for (auto& e : g_dl_events) if (e.id == (uint32_t)id) PI(@"  event %s", DlStr(e).c_str());
    A->Check("no-file-after-restart", FileSize(MidPath()) == 0 && ![NSFileManager.defaultManager fileExistsAtPath:MidPath()], [NSString stringWithFormat:@"files %@", DirListing()]);
    A->Check("no-resume-request", [ServerLogSinceStart() rangeOfString:@"/mid.bin"].location == NSNotFound, [NSString stringWithFormat:@"server log since launch start: %@", [ServerLogSinceStart() stringByReplacingOccurrencesOfString:@"\n" withString:@" | "]]);
    A->Check("never-in-progress-again", EventsFor((uint32_t)id, 0, AnyInProgress) == 0, [NSString stringWithFormat:@"%zu in-progress events for id %llu", EventsFor((uint32_t)id, 0, AnyInProgress), id]);
    if (kProfileApi) {
      const DlEv* e = FirstNoBrowserEvent((uint32_t)id);
      A->Check("replayed-as-canceled", e && e->canceled, e ? [NSString stringWithFormat:@"%s", DlStr(*e).c_str()] : @"no browser=0 event for the item");
    }
    DownloadsPageText(h, [=](NSString* txt) {
      NSString* st = RowStatus(txt, @"mid.bin");
      A->Check("downloads-page-says-canceled", [st isEqualToString:@"Canceled"], [NSString stringWithFormat:@"chrome://downloads row mid.bin status word: %@", st ?: @"(no row)"]);
      n();
    });
  });
  S->push_back([=](Next) { Done(h, A->ok(), [NSString stringWithFormat:@"control client-cancelled: %@", A->Summary()]); });
  RunSteps(S);
}
// A rejected download (file:///etc/hosts requested for a page process that may not read it: DownloadRequestUtils::IsURLSafe fails and an interrupted download without WebContents is created) is cancelled at creation and never shows as in progress.
void ControlRejected(H h) {
  if (!DlEnv(h)) return;
  auto A = std::make_shared<Asserts>();
  auto S = std::make_shared<std::vector<Step>>();
  auto logged0 = std::make_shared<size_t>(0);
  // CEF logs "Rejected download of <url>" when it cancels a download that has no browser; count it to prove the rejected path ran.
  auto rejectedLines = [] {
    NSString* log = [NSString stringWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Probe/probe.log"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
    return [log componentsSeparatedByString:@"Rejected download of file:///etc/hosts"].count - 1;
  };
  S->push_back([=](Next n) { *logged0 = rejectedLines(); h->first()->GetHost()->StartDownload("file:///etc/hosts"); Later(4, n); });
  S->push_back([=](Next n) {
    A->Check("rejected-path-ran", rejectedLines() > *logged0, [NSString stringWithFormat:@"'Rejected download of file:///etc/hosts' log lines %zu -> %zu (want more)", *logged0, rejectedLines()]);
    PI(@"events: %zu; files: %@", g_dl_events.size(), DirListing());
    for (auto& e : g_dl_events) PI(@"  event %s", DlStr(e).c_str());
    size_t inprog = 0;
    for (auto& e : g_dl_events) if (e.inprog) inprog++;
    A->Check("never-in-progress", inprog == 0, [NSString stringWithFormat:@"%zu in-progress events delivered for the rejected URL", inprog]);
    A->Check("no-file", [DirListing() isEqualToString:@"(empty)"], [NSString stringWithFormat:@"files %@", DirListing()]);
    DownloadsPageText(h, [=](NSString* txt) {
      NSString* st = RowStatus(txt, @"hosts");
      PI(@"chrome://downloads row hosts status word: %@ (text: %@)", st ?: @"(no row)", txt);
      A->Check("downloads-page-row-cancelled-or-absent", !st || [st isEqualToString:@"Canceled"], [NSString stringWithFormat:@"status word %@", st ?: @"(no row)"]);
      n();
    });
  });
  S->push_back([=](Next) { Done(h, A->ok(), [NSString stringWithFormat:@"control rejected download: %@", A->Summary()]); });
  RunSteps(S);
}
// No profile handler set: behavior is today's. The tab's own handler gets the events (browser always set), the download proceeds, nothing crashes.
void ControlNoProfile(H h) {
  if (!DlEnv(h)) return;
  auto A = std::make_shared<Asserts>();
  auto c0 = std::make_shared<unsigned long long>(0);
  auto S = std::make_shared<std::vector<Step>>();
  S->push_back([=](Next n) {
    StartMidInFirstTab(h);
    WaitFor(h, 30000, [=] { return !g_dl_events.empty() && g_dl_events.back().recv > 1000000; }, [=](bool ok) {
      if (!ok) { Done(h, false, @"download never started"); return; }
      *c0 = DirBytes(); n();
    });
  });
  S->push_back(Sleep(3));
  S->push_back([=](Next n) {
    A->Check("download-proceeds-with-tab-handler", DirBytes() > *c0 + 1000000, [NSString stringWithFormat:@"dir bytes %llu -> %llu over 3 s", *c0, DirBytes()]);
    A->Check("all-events-carry-a-browser", EventsFor(g_dl_events.back().id, 0, NoBrowser) == 0, [NSString stringWithFormat:@"%zu of %zu events had browser=0 (want 0, no profile handler)", EventsFor(g_dl_events.back().id, 0, NoBrowser), g_dl_events.size()]);
    n();
  });
  // Also the positive control of the measuring chain: the download finishes and its SHA-256 equals the server's pattern.
  S->push_back([=](Next n) {
    WaitFor(h, 40000, [=] { return FileSize(MidPath()) == kMid && g_dl_events.back().complete; }, [=](bool done) {
      A->Check("completes-within-40s", done, [NSString stringWithFormat:@"files %@; last event: %s", DirListing(), DlStr(g_dl_events.back()).c_str()]);
      NSString* got = done ? FileSha(MidPath(), kMid) : @"";
      NSString* want = PatternSha(kMid);
      A->Check("sha256-equals-pattern", [got isEqualToString:want], [NSString stringWithFormat:@"file %@ expected %@", got.length ? got : @"(unreadable or short)", want]);
      n();
    });
  });
  S->push_back([=](Next) { Done(h, A->ok(), [NSString stringWithFormat:@"control no profile handler: %@", A->Summary()]); });
  RunSteps(S);
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

// ---- M1.4 zoom bubble (patch 0007) ----
// Zoom steps through IDC_ZOOM_PLUS/MINUS; the check fails if a NativeWidgetMacNSWindow (the bubble's class) shows up in NSApp.windows at any
// sample (right after the command, then every 20 ms for 700 ms) or if the zoom level did not move as expected.
void CheckZoomNoBubble(H h) {
  auto base = std::make_shared<NSSet*>(WindowSet());
  auto bubbles = std::make_shared<int>(0), seen = std::make_shared<int>(0);
  auto logged = std::make_shared<std::set<void*>>();
  auto sample = [=](const char* when) {
    for (NSWindow* w in NSApp.windows) {
      if ([*base containsObject:[NSValue valueWithNonretainedObject:w]]) continue;
      bool isBubble = strcmp(class_getName([w class]), "NativeWidgetMacNSWindow") == 0;
      if (isBubble) (*bubbles)++;
      if (!logged->insert((__bridge void*)w).second) continue;  // log each distinct window once, count every sighting
      (*seen)++;
      PI(@"%s NEW window class=%s frame=%@ alpha=%.2f visible=%d bubble-class=%d", when, class_getName([w class]), NSStringFromRect(w.frame), w.alphaValue, (int)w.isVisible, (int)isBubble);
    }
  };
  auto level = [=] { return h->first()->GetHost()->GetZoomLevel(); };
  h->view()->SetActiveTab(h->first());
  h->first()->GetHost()->SetZoomLevel(0);
  Later(1.5, [=] {
    *base = WindowSet();
    auto levels = std::make_shared<std::vector<double>>();
    levels->push_back(level());
    const char* cmds[3] = { "IDC_ZOOM_PLUS", "IDC_ZOOM_PLUS", "IDC_ZOOM_MINUS" };
    auto step = std::make_shared<std::function<void(int)>>();
    *step = [=](int i) {
      if (i == 3) {
        bool moved = levels->at(1) > levels->at(0) && levels->at(2) > levels->at(1) && levels->at(3) < levels->at(2);
        PI(@"zoom levels initial=%.3f +=%.3f ++=%.3f -=%.3f moved-as-expected=%d; new windows seen=%d bubble-class windows=%d", levels->at(0), levels->at(1), levels->at(2), levels->at(3), (int)moved, *seen, *bubbles);
        h->first()->GetHost()->SetZoomLevel(0);
        Done(h, moved && *bubbles == 0, moved ? (*bubbles == 0 ? @"no zoom bubble window and zoom moved as expected" : @"zoom bubble window appeared") : @"zoom level did not move as expected");
        return;
      }
      h->first()->GetHost()->ExecuteChromeCommand(cef_id_for_command_id_name(cmds[i]), CEF_WOD_CURRENT_TAB);
      sample(cmds[i]);
      double t0 = NowMs();
      auto poll = std::make_shared<std::function<void()>>();
      *poll = [=] {
        sample(cmds[i]);
        if (NowMs() - t0 < 700) { Later(0.02, *poll); return; }
        levels->push_back(level());
        (*step)(i + 1);
      };
      Later(0.02, *poll);
    };
    (*step)(0);
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


// ---- patch 0009 research: tab discarding (note m1-6 3.1 to 3.4, probes P1, P1b, P2, P3) ----
struct DiscStat { int created = 0, closed = 0, loads = 0, discardedCb = 0, restoredCb = 0; };
std::map<int, DiscStat> g_ds;  // browser id -> callbacks seen by the per-tab client
bool g_ds_quiet = false;       // set once the verdict is out: no more lines after it
class DiscClient : public CefClient, public CefLifeSpanHandler, public CefLoadHandler
#ifdef NOCHE_DISCARD_API
    , public CefDisplayHandler
#endif
{
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
#ifdef NOCHE_DISCARD_API
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  void OnTabDiscarded(CefRefPtr<CefBrowser> b, bool discarded) override {
    (discarded ? g_ds[b->GetIdentifier()].discardedCb : g_ds[b->GetIdentifier()].restoredCb)++;
    if (!g_ds_quiet) PI(@"callback OnTabDiscarded browser=%d discarded=%d t=%.0fms", b->GetIdentifier(), (int)discarded, NowMs() - g_t0);
  }
#endif
  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    g_ds[b->GetIdentifier()].created++;
    if (!g_ds_quiet) PI(@"callback OnAfterCreated browser=%d t=%.0fms", b->GetIdentifier(), NowMs() - g_t0);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> b) override {
    g_ds[b->GetIdentifier()].closed++;
    if (!g_ds_quiet) PI(@"callback OnBeforeClose browser=%d t=%.0fms", b->GetIdentifier(), NowMs() - g_t0);
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, int status) override {
    if (!f->IsMain()) return;
    g_ds[b->GetIdentifier()].loads++;
    g_load[b->GetIdentifier()] = status;
    if (!g_ds_quiet) PI(@"callback OnLoadEnd browser=%d status=%d t=%.0fms", b->GetIdentifier(), status, NowMs() - g_t0);
  }
 private:
  IMPLEMENT_REFCOUNTING(DiscClient);
};

void DiscDone(const H& h, bool ok, NSString* d) { g_ds_quiet = true; Done(h, ok, d); }
int DiscTab(const H& h, NSString* url, bool activate = false) {
  auto v = h->view();
  auto b = v ? v->AddTab(url.UTF8String, new DiscClient(), CefBrowserSettings(), nullptr, activate) : nullptr;
  return b ? b->GetIdentifier() : -1;
}
NSString* Slim(NSString* u) { NSRange r = [u rangeOfString:@"/" options:NSBackwardsSearch]; return r.location == NSNotFound ? u : [u substringFromIndex:r.location + 1]; }
// Every tab the view lists, by id, with its main frame URL and the per-tab client's counters.
NSString* DiscDump(const H& h) {
  std::vector<CefRefPtr<CefBrowser>> t;
  if (auto v = h->view()) v->GetTabs(t);
  auto act = ActiveId(h);
  NSMutableArray* o = [NSMutableArray array];
  for (auto& b : t) {
    auto& s = g_ds[b->GetIdentifier()];
    [o addObject:[NSString stringWithFormat:@"%d%s[valid=%d url=%@ loading=%d created=%d closed=%d loads=%d]", b->GetIdentifier(), b->GetIdentifier() == act ? "*" : "", (int)b->IsValid(), Slim(@(b->GetMainFrame()->GetURL().ToString().c_str())), (int)b->IsLoading(), s.created, s.closed, s.loads]];
  }
  return [NSString stringWithFormat:@"%zu tabs, active=%d: %@", t.size(), act, [o componentsJoinedByString:@" "]];
}
NSString* ArgsFact() {
  auto cl = CefCommandLine::GetGlobalCommandLine();
  auto sw = [&](const char* n) { return cl && cl->HasSwitch(n) ? [NSString stringWithFormat:@"--%s=%s", n, cl->GetSwitchValue(n).ToString().c_str()] : [NSString stringWithFormat:@"(no --%s)", n]; };
  return [NSString stringWithFormat:@"%@ %@ %@ %@ (CefCommandLine::GetGlobalCommandLine)", sw("enable-features"), sw("disable-features"), sw("disable-renderer-backgrounding"), sw("disable-background-timer-throttling")];
}
void ExtJson(const H& h, NSDictionary* cmd, std::function<void(NSDictionary*)> cb) { h->extCmd(cmd, cb); }
NSString* Js(NSDictionary* d) {
  NSData* j = [NSJSONSerialization dataWithJSONObject:d ?: @{} options:0 error:nil];
  return j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
}
NSString* TabsInfoLine(NSDictionary* r) {
  if (r[@"error"]) return [NSString stringWithFormat:@"tabsinfo error: %@", r[@"error"]];
  NSMutableArray* o = [NSMutableArray array];
  for (NSDictionary* t in r[@"tabs"]) [o addObject:[NSString stringWithFormat:@"%@%@[%@ idx=%@ discarded=%@ pinned=%@ autoDiscardable=%@ status=%@]", t[@"id"], [t[@"active"] boolValue] ? @"*" : @"", Slim(t[@"url"] ?: @"?"), t[@"index"], t[@"discarded"], t[@"pinned"], t[@"autoDiscardable"], t[@"status"]]];
  return [NSString stringWithFormat:@"chrome.tabs: %@", [o componentsJoinedByString:@" "]];
}
NSNumber* ChromeIdFor(NSDictionary* r, NSString* needle) {
  for (NSDictionary* t in r[@"tabs"]) if ([(t[@"url"] ?: @"") containsString:needle]) return t[@"id"];
  return nil;
}
NSDictionary* ChromeTab(NSDictionary* r, NSString* needle) {
  for (NSDictionary* t in r[@"tabs"]) if ([(t[@"url"] ?: @"") containsString:needle]) return t;
  return nil;
}
// A tab whose main frame URL contains |needle| (the browser id can change when a WebContents is replaced).
CefRefPtr<CefBrowser> ByUrl(const H& h, NSString* needle) {
  std::vector<CefRefPtr<CefBrowser>> t;
  if (auto v = h->view()) v->GetTabs(t);
  for (auto& b : t) if ([@(b->GetMainFrame()->GetURL().ToString().c_str()) containsString:needle]) return b;
  return nullptr;
}

// Target.getTargetInfo of a tab's own DevTools session: a new targetId after a discard means the WebContents (and its agent host) was replaced.
void TargetIdOf(const H& h, int id, const char* label, std::function<void()> next) {
  auto b = ById(h, id);
  if (!b) { PI(@"%s: tab %d has no CefBrowser", label, id); next(); return; }
  h->cdp(b, @"Target.getTargetInfo", @{}, [=](NSDictionary* r) {
    NSDictionary* ti = r[@"result"][@"targetInfo"];
    PI(@"%s: tab %d Target.getTargetInfo -> %@", label, id, ti ? [NSString stringWithFormat:@"targetId=%@ type=%@ url=%@", ti[@"targetId"], ti[@"type"], Slim(ti[@"url"] ?: @"")] : Js(r));
    next();
  });
}

// P1 (feature on, from the bridge): 6 tabs (first active, 5 background), discard the 5 through chrome.tabs.discard (the extension API
// that ends in the lifecycle unit, like chrome://discards), then activate one, then try the active tab. Judged (P1 only): at least one
// background tab discarded, every CefBrowser id still valid, activating the discarded tab reloads (OnLoadEnd fires), and the process lives.
void CheckDiscard(H h) {
  PI(@"mode: WebContentsDiscard ON (the bridge enables it by name); switches: %@", ArgsFact());
  auto ids = std::make_shared<std::vector<int>>();
  for (int i = 1; i <= 5; i++) ids->push_back(DiscTab(h, Page(h, [NSString stringWithFormat:@"index.html?t=%d", i])));
  PI(@"AddTab ids %d %d %d %d %d (first tab %d, active %d)", (*ids)[0], (*ids)[1], (*ids)[2], (*ids)[3], (*ids)[4], h->first()->GetIdentifier(), ActiveId(h));
  WaitFor(h, 20000, [=] { for (int id : *ids) if (id < 0 || !g_load.count(id)) return false; return true; }, [=](bool loaded) {
    if (!loaded) { DiscDone(h, false, @"background tabs did not finish loading in 20 s"); return; }
    ExtJson(h, @{@"what" : @"tabsinfo"}, [=](NSDictionary* before) {
      PI(@"before: %@", TabsInfoLine(before));
      PI(@"before: cef %@", DiscDump(h));
      TargetIdOf(h, (*ids)[0], "before discard", [=] {
      auto discardedOk = std::make_shared<int>(0), replied = std::make_shared<int>(0);
      auto step = std::make_shared<std::function<void(int)>>();
      *step = [=](int i) {
        if (i == 5) {
          Later(2.0, [=] { *step = nullptr;
            ExtJson(h, @{@"what" : @"tabsinfo"}, [=](NSDictionary* after) {
              int nDisc = 0;
              for (NSDictionary* t in after[@"tabs"]) if ([t[@"discarded"] boolValue]) nDisc++;
              PI(@"after discarding 5 background tabs: %@", TabsInfoLine(after));
              PI(@"after: cef %@", DiscDump(h));
              PI(@"after: %@", h->fallback());
              bool allValid = true; int missing = 0;
              for (int id : *ids) { auto b = ById(h, id); if (!b || !b->IsValid()) { allValid = false; missing++; } }
              PI(@"summary: discard calls ok=%d replied=%d, chrome.tabs discarded=%d, original CefBrowser ids missing or invalid=%d", *discardedOk, *replied, nDisc, missing);
              // activate the discarded t=1 tab and time the reload
              auto target = ByUrl(h, @"t=1");
              int tid = target ? target->GetIdentifier() : (*ids)[0];
              int loadsBefore = g_ds[tid].loads;
              double t0 = NowMs();
              auto tb = ById(h, tid);
              if (!tb) { PI(@"activate: no CefBrowser with id %d (replaced?)", tid); DiscDone(h, false, [NSString stringWithFormat:@"discarded=%d, browser %d gone after discard", nDisc, tid]); return; }
              h->view()->SetActiveTab(tb);
              WaitFor(h, 10000, [=] { return g_ds[tid].loads > loadsBefore; }, [=](bool reloaded) {
                double ms = NowMs() - t0;
                PI(@"activate discarded tab %d: OnLoadEnd %s after %.0f ms; active=%d", tid, reloaded ? "fired" : "did NOT fire within 10 s", ms, ActiveId(h));
                Eval(h, tid, @"JSON.stringify({href: location.href, vis: document.visibilityState, wasDiscarded: document.wasDiscarded})", false, [=](NSString* r) {
                  PI(@"activated tab page state: %@", r.length ? r : @"(no value)");
                  TargetIdOf(h, tid, "after reload", [=] {
                  ExtJson(h, @{@"what" : @"tabsinfo"}, [=](NSDictionary* mid) {
                    PI(@"after activation: %@", TabsInfoLine(mid));
                    NSNumber* actChrome = nil;
                    for (NSDictionary* t in mid[@"tabs"]) if ([t[@"active"] boolValue]) actChrome = t[@"id"];
                    ExtJson(h, @{@"what" : @"discard", @"id" : actChrome ?: @0}, [=](NSDictionary* dr) {
                      PI(@"explicit chrome.tabs.discard of the ACTIVE tab (chrome id %@): %@", actChrome, Js(dr));
                      Later(1.5, [=] {
                        ExtJson(h, @{@"what" : @"tabsinfo"}, [=](NSDictionary* fin) {
                          PI(@"after active-tab attempt: %@", TabsInfoLine(fin));
                          PI(@"after active-tab attempt: cef %@", DiscDump(h));
                          PI(@"final: %@", h->fallback());
                          bool ok = nDisc >= 1 && allValid && reloaded;
                          NSString* d = [NSString stringWithFormat:@"discarded=%d of 5 background tabs, all original CefBrowser ids valid=%d, activation reload OnLoadEnd=%d (%.0f ms), active-tab explicit discard reply %@", nDisc, (int)allValid, (int)reloaded, ms, Js(dr)];
                          DiscDone(h, ok, d);
                        });
                      });
                    });
                  });
                  });
                });
              });
            });
          });
          return;
        }
        NSNumber* cid = ChromeIdFor(before, [NSString stringWithFormat:@"t=%d", i + 1]);
        if (!cid) { PI(@"no chrome tab id for t=%d", i + 1); (*step)(i + 1); return; }
        double t0 = NowMs();
        ExtJson(h, @{@"what" : @"discard", @"id" : cid}, [=](NSDictionary* r) {
          (*replied)++;
          if (r[@"ok"] && [r[@"ok"] boolValue]) (*discardedOk)++;
          PI(@"chrome.tabs.discard(t=%d chrome id %@) -> %@ in %.0f ms", i + 1, cid, Js(r), NowMs() - t0);
          Later(0.5, [=] { (*step)(i + 1); });
        });
      };
      (*step)(0);
      });
    });
  });
}

// discard-p1b and discard-p1b-off: the feature is truly off. The bridge enables WebContentsDiscard on every launch, and the probe adds --disable-features=WebContentsDiscard;
// the disable list wins (base/feature_list.cc:454 registers --disable-features before --enable-features, and RegisterOverride at :1470 keeps only the first override of a name).
// Asserts the switch is on the command line, then that DiscardTab() on a loaded background tab returns false, the browser stays valid and OnTabDiscarded never runs.
void CheckDiscardOff(H h) {
#ifndef NOCHE_DISCARD_API
  PI(@"CefBrowserHost::DiscardTab is not in this engine build (NOCHE_DISCARD_API unset): nothing to call; needs patch 0009");
  DiscDone(h, false, @"NOT RUN: engine patch 0009 API missing (build with NOCHE_DISCARD_API=1 against the 0009 engine)");
#else
  PI(@"mode: WebContentsDiscard OFF (--disable-features=WebContentsDiscard beats the bridge's --enable-features); switches: %@", ArgsFact());
  auto cl = CefCommandLine::GetGlobalCommandLine();
  const std::string dis = cl ? cl->GetSwitchValue("disable-features").ToString() : "";
  const bool offOnLine = ("," + dis + ",").find(",WebContentsDiscard,") != std::string::npos;
  int a = DiscTab(h, Page(h, @"index.html?t=31"));
  if (a < 0) { DiscDone(h, false, @"AddTab returned NULL"); return; }
  WaitFor(h, 20000, [=] { return g_load.count(a) > 0; }, [=](bool loaded) {
    if (!loaded) { DiscDone(h, false, @"tab did not finish loading in 20 s"); return; }
    auto ba = ById(h, a);
    const bool background = a != ActiveId(h);
    const bool r = ba && ba->GetHost()->DiscardTab();
    PI(@"DiscardTab() on background tab %d (background=%d) returned %d", a, (int)background, (int)r);
    Later(2.0, [=] {
      auto after = ById(h, a);
      const bool valid = after && after->IsValid();
      PI(@"after: %@; OnTabDiscarded(true) calls %d, (false) calls %d", DiscDump(h), g_ds[a].discardedCb, g_ds[a].restoredCb);
      DiscDone(h, offOnLine && background && !r && valid && g_ds[a].discardedCb == 0 && g_ds[a].restoredCb == 0,
               [NSString stringWithFormat:@"feature off on the command line=%d, background=%d, DiscardTab()=%d (want 0), browser valid=%d, OnTabDiscarded calls=%d/%d (want 0/0)", (int)offOnLine, (int)background, (int)r, (int)valid, g_ds[a].discardedCb, g_ds[a].restoredCb]);
    });
  });
#endif
}

// P2: pin immunity. chrome://discards (its mojo DetailsProvider, loaded from the page with a dynamic import) lists can_discard and the reasons, and
// discards by tab with the URGENT reason (the policy path, not the always-allowed EXTERNAL one). Tabs are matched by URL or focus on every call,
// because the listing's ids are not stable between calls. A pinned tab must refuse; an unpinned control and the active tab (URGENT) are recorded;
// chrome.tabs.discard (EXTERNAL) of the pinned tab is recorded last.
void CheckDiscardP2(H h) {
  PI(@"mode: WebContentsDiscard ON; switches: %@", ArgsFact());
  int pinned = DiscTab(h, Page(h, @"index.html?t=11")), ctl = DiscTab(h, Page(h, @"index.html?t=12")), ui = DiscTab(h, @"chrome://discards/");
  PI(@"AddTab pinned-candidate=%d control=%d chrome://discards=%d first=%d", pinned, ctl, ui, h->first()->GetIdentifier());
  if (pinned < 0 || ctl < 0 || ui < 0) { DiscDone(h, false, @"AddTab returned NULL"); return; }
  static NSString* kSetup = @"(async()=>{try{const m=await import('chrome://discards/discards.mojom-webui.js');const l=await import('chrome://discards/lifecycle_unit_state.mojom-webui.js');window.__dp=m.DetailsProvider.getRemote();window.__R=l.LifecycleUnitDiscardReason;window.__S=l.LifecycleUnitState;window.__nm=(v)=>Object.keys(window.__S).find(k=>k!=='MIN_VALUE'&&k!=='MAX_VALUE'&&window.__S[k]===v)||v;return 'ok reasons='+JSON.stringify(window.__R)}catch(e){return 'import failed: '+e}})()";
  static NSString* kInfo = @"(async()=>{try{const r=await window.__dp.getTabDiscardsInfo();return JSON.stringify(r.infos.map(i=>({id:i.id,url:i.tabUrl.split('/').pop(),state:window.__nm(i.state),canDiscard:i.canDiscard,why:i.cannotDiscardReasons,discardCount:i.discardCount,auto:i.isAutoDiscardable,vis:i.visibility,focus:i.hasFocus})))}catch(e){return 'info failed: '+e}})()";
  auto discardWhere = [=](NSString* pred, NSString* what, std::function<void()> next) {
    NSString* js = [NSString stringWithFormat:@"(async()=>{try{const r=await window.__dp.getTabDiscardsInfo();const i=r.infos.find(%@);if(!i)return 'no match';await window.__dp.discardById(i.id, window.__R.URGENT);return 'sent id='+i.id+' url='+i.tabUrl.split('/').pop()}catch(e){return 'failed: '+e}})()", pred];
    Eval(h, ui, js, true, [=](NSString* r) { PI(@"webui discardById(URGENT) for %@ -> %@", what, r); Later(1.5, next); });
  };
  WaitFor(h, 20000, [=] { return g_load.count(pinned) && g_load.count(ctl) && g_load.count(ui); }, [=](bool loaded) {
    if (!loaded) { DiscDone(h, false, @"tabs did not finish loading in 20 s"); return; }
    ExtJson(h, @{@"what" : @"tabsinfo"}, [=](NSDictionary* t0) {
      NSNumber* pid = ChromeIdFor(t0, @"t=11");
      ExtJson(h, @{@"what" : @"pin", @"id" : pid ?: @0, @"pinned" : @YES}, [=](NSDictionary* pr) {
        PI(@"chrome.tabs.update(t=11 chrome id %@, pinned:true) -> %@", pid, Js(pr));
        Eval(h, ui, kSetup, true, [=](NSString* setup) {
          PI(@"webui setup: %@", setup.length ? setup : @"(no value)");
          if (![setup hasPrefix:@"ok"]) { DiscDone(h, false, [NSString stringWithFormat:@"chrome://discards mojo not reachable from the page: %@", setup]); return; }
          Eval(h, ui, kInfo, true, [=](NSString* info0) {
            PI(@"webui info before: %@", info0);
            discardWhere(@"(i)=>i.tabUrl.endsWith('index.html?t=11')", @"the PINNED tab", [=] {
              discardWhere(@"(i)=>i.tabUrl.endsWith('index.html?t=12')", @"the unpinned control", [=] {
                discardWhere(@"(i)=>i.hasFocus", @"the ACTIVE (focused) tab", [=] {
                  Eval(h, ui, kInfo, true, [=](NSString* info1) {
                    PI(@"webui info after: %@", info1);
                    NSArray* a1 = [NSJSONSerialization JSONObjectWithData:[info1 dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                    NSDictionary *p = nil, *c = nil, *act = nil;
                    for (NSDictionary* i in a1) {
                      if ([i[@"url"] isEqualToString:@"index.html?t=11"]) p = i;
                      if ([i[@"url"] isEqualToString:@"index.html?t=12"]) c = i;
                      if ([i[@"focus"] boolValue]) act = i;
                    }
                    auto discarded = [](NSDictionary* i) { return i && ([i[@"discardCount"] intValue] > 0 || [i[@"state"] isEqual:@"DISCARDED"]); };
                    bool pOk = p && !discarded(p), cDisc = discarded(c), aOk = act && !discarded(act);
                    PI(@"pinned t=11 reasons %@; active tab discarded by URGENT=%d", p[@"why"], (int)!aOk);
                    ExtJson(h, @{@"what" : @"tabsinfo"}, [=](NSDictionary* t1) {
                      PI(@"after: %@", TabsInfoLine(t1));
                      ExtJson(h, @{@"what" : @"discard", @"id" : ChromeIdFor(t1, @"t=11") ?: @0}, [=](NSDictionary* er) {
                        PI(@"explicit chrome.tabs.discard (EXTERNAL) of the PINNED tab -> %@", Js(er));
                        Later(1.5, [=] {
                          PI(@"final cef %@", DiscDump(h));
                          NSString* d = [NSString stringWithFormat:@"pinned tab survived the URGENT discard=%d, unpinned control discarded by the same call=%d (the control must discard or the pin result proves nothing), active tab survived URGENT=%d", (int)pOk, (int)cDisc, (int)aOk];
                          DiscDone(h, pOk && cDisc && aOk, d);
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
  });
}

// P3: hidden-tab treatment inside one Browser. Tab T (page discard-ticks.html: 100 ms interval, visibility and lifecycle events) is active for
// 4 s (baseline), then another tab is activated; T is sampled every 5 s for 50 s: ticks per second over the last window, visibilityState, events.
void CheckDiscardP3(H h) {
  PI(@"mode: default background treatment (no anti-throttling switches); switches: %@", ArgsFact());
  int t = DiscTab(h, Page(h, @"discard-ticks.html"), true);
  if (t < 0) { DiscDone(h, false, @"AddTab returned NULL"); return; }
  WaitFor(h, 15000, [=] { return g_load.count(t) > 0; }, [=](bool) {
    PI(@"tab T=%d active=%d first=%d", t, ActiveId(h), h->first()->GetIdentifier());
    auto read = [=](NSString* label, std::function<void(NSDictionary*)> cb) {
      Eval(h, t, @"JSON.stringify({ticks: window.__d.ticks, now: Math.round(performance.now()), vis: document.visibilityState, hidden: document.hidden, ev: window.__d.ev})", false, [=](NSString* r) {
        NSDictionary* j = r.length ? [NSJSONSerialization JSONObjectWithData:[r dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        PI(@"%@: %@", label, r.length ? r : @"(no value)");
        cb([j isKindOfClass:NSDictionary.class] ? j : @{});
      });
    };
    Later(4.0, [=] {
      read(@"visible baseline end", [=](NSDictionary* a) {
        double baseTicks = [a[@"ticks"] doubleValue], baseNow = [a[@"now"] doubleValue];
        double baseRate = baseNow > 0 ? baseTicks / (baseNow / 1000.0) : 0;
        PI(@"visible tick rate %.2f per second (%.0f ticks in %.0f ms) visibilityState=%@", baseRate, baseTicks, baseNow, a[@"vis"]);
        auto first = h->first();
        h->view()->SetActiveTab(first);
        double hideAt = NowMs();
        auto lastTicks = std::make_shared<double>([a[@"ticks"] doubleValue]), lastNow = std::make_shared<double>([a[@"now"] doubleValue]);
        auto lastRate = std::make_shared<double>(-1);
        auto lastVis = std::make_shared<NSString*>(@"?");
        auto hiddenFlag = std::make_shared<bool>(false);
        auto freezeAt = std::make_shared<double>(-1);
        auto rate10 = std::make_shared<double>(-1);
        auto sample = std::make_shared<std::function<void(int)>>();
        *sample = [=](int n) {
          if (n > 9) {
            Later(0, [sample] { *sample = nullptr; });  // not from inside the closure that is running
            bool hid = *hiddenFlag && [*lastVis isEqualToString:@"hidden"];
            PI(@"summary: visible %.2f/s; hidden last-window rate %.2f/s (rate in the 5 s window after 10 s hidden: %.2f/s); hidden=%d visibilityState=%@; freeze event %@", baseRate, *lastRate, *rate10, (int)*hiddenFlag, *lastVis, *freezeAt >= 0 ? [NSString stringWithFormat:@"at %.1f s hidden", *freezeAt / 1000] : @"none within 50 s hidden");
            DiscDone(h, baseRate >= 8 && hid && *rate10 >= 0 && *rate10 <= 2.5, [NSString stringWithFormat:@"visible %.2f/s, hidden after 10 s %.2f/s (want <= 2.5, about 1), hidden=%d, freeze %@", baseRate, *rate10, (int)hid, *freezeAt >= 0 ? [NSString stringWithFormat:@"%.1f s", *freezeAt / 1000] : @"not within 50 s"]);
            return;
          }
          Later(5.0, [=] {
            read([NSString stringWithFormat:@"hidden +%.1f s", (NowMs() - hideAt) / 1000], [=](NSDictionary* r) {
              double dt = ([r[@"now"] doubleValue] - *lastNow) / 1000.0;
              if (dt > 0) { *lastRate = ([r[@"ticks"] doubleValue] - *lastTicks) / dt; if (n == 2) *rate10 = *lastRate; if (n == 3 && *rate10 < 0) *rate10 = *lastRate; }
              PI(@"hidden window %d: %.2f ticks/s over %.1f s", n + 1, *lastRate, dt);
              *lastTicks = [r[@"ticks"] doubleValue]; *lastNow = [r[@"now"] doubleValue];
              *hiddenFlag = [r[@"hidden"] boolValue]; *lastVis = r[@"vis"] ?: @"?";
              for (NSArray* e in r[@"ev"]) if ([e[0] isEqual:@"freeze"] && *freezeAt < 0) *freezeAt = [e[1] doubleValue] - 0;
              (*sample)(n + 1);
            });
          });
        };
        (*sample)(0);
      });
    });
  });
}

// discard-api: the 0009 engine API (CefBrowserHost::DiscardTab, CefDisplayHandler::OnTabDiscarded). Compiled only with NOCHE_DISCARD_API=1.
void CheckDiscardApi(H h) {
#ifndef NOCHE_DISCARD_API
  PI(@"CefBrowserHost::DiscardTab and CefDisplayHandler::OnTabDiscarded are not in this engine build (NOCHE_DISCARD_API unset): nothing to call; needs patch 0009");
  DiscDone(h, false, @"NOT RUN: engine patch 0009 API missing (build with NOCHE_DISCARD_API=1 against the 0009 engine)");
#else
  PI(@"mode: WebContentsDiscard ON; switches: %@", ArgsFact());
  int a = DiscTab(h, Page(h, @"index.html?t=21")), b = DiscTab(h, Page(h, @"index.html?t=22"));
  if (a < 0 || b < 0) { DiscDone(h, false, @"AddTab returned NULL"); return; }
  WaitFor(h, 20000, [=] { return g_load.count(a) && g_load.count(b); }, [=](bool loaded) {
    if (!loaded) { DiscDone(h, false, @"tabs did not finish loading in 20 s"); return; }
    auto ba = ById(h, a);
    bool r = ba->GetHost()->DiscardTab();
    PI(@"DiscardTab() on background tab %d returned %d; active tab %d", a, (int)r, ActiveId(h));
    Later(2.0, [=] {
      PI(@"after: %@", DiscDump(h));
      auto afterDiscard = ById(h, a);
      bool validAfter = afterDiscard && afterDiscard->IsValid();
      bool discardedCb = g_ds[a].discardedCb == 1;
      PI(@"OnTabDiscarded(true) calls for %d: %d", a, g_ds[a].discardedCb);
      int act = ActiveId(h);
      auto ac = ById(h, act);
      bool activeRefused = ac && !ac->GetHost()->DiscardTab();
      PI(@"DiscardTab() on the active tab %d refused=%d", act, (int)activeRefused);
      int loads = g_ds[a].loads;
      h->view()->SetActiveTab(ById(h, a));
      WaitFor(h, 10000, [=] { return g_ds[a].loads > loads; }, [=](bool reloaded) {
        PI(@"activation of the discarded tab: reload OnLoadEnd=%d OnTabDiscarded(false) calls=%d browser valid after discard=%d", (int)reloaded, g_ds[a].restoredCb, (int)validAfter);
        Eval(h, a, @"String(document.wasDiscarded)", false, [=](NSString* wd) {
          PI(@"document.wasDiscarded after activation -> %@", wd.length ? wd : @"(no value)");
          DiscDone(h, r && discardedCb && activeRefused && reloaded && g_ds[a].restoredCb == 1 && validAfter && [wd containsString:@"true"], [NSString stringWithFormat:@"DiscardTab + OnTabDiscarded(true then false) + active tab refused + reload + browser valid after discard=%d + document.wasDiscarded=%@", (int)validAfter, wd]);
        });
      });
    });
  });
#endif
}

#ifdef NOCHE_DISCARD_API
// Summed RSS in MB (decimal) of this probe's renderer processes (extension renderers included) and how many there are.
static double RendererRssMB(int* n) {
  FILE* f = popen("/bin/ps -axo pid=,ppid=,rss=,command=", "r");
  long kb = 0;
  int count = 0;
  char line[8192];
  while (f && fgets(line, sizeof line, f)) {
    int pid, ppid, off = 0;
    long rss;
    if (sscanf(line, "%d %d %ld %n", &pid, &ppid, &rss, &off) < 3) continue;
    if (strstr(line + off, "Noche Probe") && strstr(line + off, "--type=renderer")) { kb += rss; count++; }
  }
  if (f) pclose(f);
  if (n) *n = count;
  return kb * 1024.0 / 1e6;
}
#endif

// discard-p5 (note m1-6 5.3 P5): 30 tabs of a heavy page (30 MB touched each), renderer RSS before and after DiscardTab on 20 of the background ones.
void CheckDiscardP5(H h) {
#ifndef NOCHE_DISCARD_API
  DiscDone(h, false, @"NOT RUN: engine patch 0009 API missing (build with NOCHE_DISCARD_API=1 against the 0009 engine)");
#else
  PI(@"mode: WebContentsDiscard ON; switches: %@", ArgsFact());
  auto ids = std::make_shared<std::vector<int>>();
  for (int i = 1; i <= 30; i++) ids->push_back(DiscTab(h, Page(h, [NSString stringWithFormat:@"heavy.html?t=%d", i])));
  for (int id : *ids) if (id < 0) { DiscDone(h, false, @"AddTab returned NULL"); return; }
  WaitFor(h, 60000, [=] { for (int id : *ids) if (!g_load.count(id)) return false; return true; }, [=](bool loaded) {
    if (!loaded) { DiscDone(h, false, @"30 heavy tabs did not finish loading in 60 s"); return; }
    Later(5.0, [=] {
      int p1 = 0;
      double r1 = RendererRssMB(&p1);
      PI(@"before: renderer RSS %.1f MB in %d renderer processes, 30 heavy tabs + the first tab", r1, p1);
      int nDisc = 0;
      for (int k = 0; k < 20; k++) {
        auto b = ById(h, (*ids)[k]);
        if (b && b->GetHost()->DiscardTab()) nDisc++;
      }
      PI(@"DiscardTab returned true for %d of 20 tabs; active tab %d", nDisc, ActiveId(h));
      Later(6.0, [=] {
        int p2 = 0;
        double r2 = RendererRssMB(&p2);
        double saved = r1 - r2;
        PI(@"after: renderer RSS %.1f MB in %d renderer processes; saved %.1f MB, %.1f MB per discarded tab (%d discarded)", r2, p2, saved, nDisc > 0 ? saved / nDisc : 0.0, nDisc);
        DiscDone(h, nDisc == 20 && saved > 0, [NSString stringWithFormat:@"discarded=%d of 20, renderer RSS %.1f MB (%d procs) -> %.1f MB (%d procs), %.1f MB saved, %.1f MB per tab", nDisc, r1, p1, r2, p2, saved, nDisc > 0 ? saved / nDisc : 0.0]);
      });
    });
  });
#endif
}
}  // namespace

void SurfEarly(NSString* check) {
  g_t0 = NowMs();
  g_dl_on = [check hasPrefix:@"download-"];
  g_perm_on = [check isEqualToString:@"bubbles"] ? false : false;  // bubbles switches the handler on for phase 2
  g_ctx_on = [check isEqualToString:@"ctx-ext-items"];
  g_name = check;
  g_dl = new DlHandler();
  if (g_dl_on) g_log0 = ServerLog().length;
#ifdef NOCHE_DOWNLOAD_API
  // Patch 0008: the profile handler gets the downloads that have no live browser. Set before the first navigation.
  if (g_dl_on && ![check isEqualToString:@"download-control-noprofile"]) CefRequestContext::GetGlobalContext()->SetDownloadHandler(g_dl);
#endif
  g_perm = new PermHandler();
  g_ctx = new CtxHandler();
}
CefRefPtr<CefContextMenuHandler> SurfContextMenuHandler() { return g_ctx_on ? CefRefPtr<CefContextMenuHandler>(g_ctx) : nullptr; }
CefRefPtr<CefDownloadHandler> SurfDownloadHandler() { return g_dl_on ? CefRefPtr<CefDownloadHandler>(g_dl) : nullptr; }
CefRefPtr<CefPermissionHandler> SurfPermissionHandler() { return g_perm_on ? CefRefPtr<CefPermissionHandler>(g_perm) : nullptr; }
void SurfOnLoadEnd(int id, int status) { g_load[id] = status; }

bool RunSurfacesCheck(NSString* check, const SurfHost& host) {
  if (RunProfilesCheck(check, host)) return true;
  static NSDictionary* table = @{
    @"cmd-enabled" : @0, @"bubbles" : @1, @"download-restart-1" : @2, @"download-restart-2" : @3, @"download-tab-close" : @4,
    @"ctx-ext-items" : @5, @"zoom-scope" : @6, @"chrome-pages" : @7, @"zoom-no-bubble" : @8, @"download-tab-close-start" : @9,
    @"download-restart-crash-1" : @10, @"download-restart-crash-2" : @11, @"download-control-cancel-1" : @12,
    @"download-control-cancel-2" : @13, @"download-control-rejected" : @14, @"download-control-noprofile" : @15,
    @"download-keep-stream" : @23, @"download-keep-complete" : @24, @"discard-p1" : @16, @"discard-p1b" : @17, @"discard-p1b-off" : @21, @"discard-p2" : @18, @"discard-p3" : @19, @"discard-api" : @20, @"discard-p5" : @22 };
  NSNumber* n = table[check];
  if (!n) return false;
  g_name = check;
  H h = std::make_shared<const SurfHost>(host);
  switch (n.intValue) {
    case 0: CheckCmdEnabled(h); break;
    case 1: CheckBubbles(h); break;
    case 2: DownloadRestart1(h, false); break;
    case 3: DownloadRestart2(h, false); break;
    case 4: DownloadTabClose(h, false); break;
    case 9: DownloadTabClose(h, true); break;
    case 10: DownloadRestart1(h, true); break;
    case 11: DownloadRestart2(h, true); break;
    case 12: ControlCancel1(h); break;
    case 13: ControlCancel2(h); break;
    case 14: ControlRejected(h); break;
    case 15: ControlNoProfile(h); break;
    case 5: CheckCtx(h); break;
    case 6: CheckZoom(h); break;
    case 7: CheckChromePages(h); break;
    case 16: CheckDiscard(h); break;
    case 17: CheckDiscardOff(h); break;
    case 18: CheckDiscardP2(h); break;
    case 19: CheckDiscardP3(h); break;
    case 20: CheckDiscardApi(h); break;
    case 21: CheckDiscardOff(h); break;
    case 22: CheckDiscardP5(h); break;
    case 23: KeepStream(h); break;
    case 24: KeepComplete(h); break;
    default: CheckZoomNoBubble(h); break;
  }
  return true;
}
#endif
