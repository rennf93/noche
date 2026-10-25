// Multi-profile checks (engine patch 0010 research, note m1-7 section 5). Profile "Default" is the probe's main window (the global
// context); "Profile 1" and "Profile 2" are CefRequestContext::CreateContext(cache_path = <root>/Profile n) contexts, each with its own
// hidden window. Every check records named assertions ("PROBE <check> info assert <name> PASS|FAIL: ...") and passes only if all hold.
// Hidden rule as everywhere: windows are alpha 0, click-through, never shown, activated or made key.
#import "surfaces.h"
#include "resloads.h"
#include <algorithm>
#include <chrono>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#ifndef NOCHE_TABS_API
bool RunProfilesCheck(NSString*, const SurfHost&) { return false; }
void ProfilesPreEngine(NSString*, NSString*) {}
#else
#include <sys/stat.h>
#include "include/cef_cookie.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"
#ifdef NOCHE_ACTIONS_API
#include "include/cef_extension_action.h"
#endif

namespace {

using H = std::shared_ptr<const SurfHost>;
NSString* g_name = @"";
#define PI(...) do { printf("PROBE %s info %s\n", g_name.UTF8String, [NSString stringWithFormat:__VA_ARGS__].UTF8String); fflush(stdout); } while (0)

// ---- plumbing ----
void Later(double sec, std::function<void()> f) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ f(); });
}
void WaitFor(H h, int timeoutMs, std::function<bool()> cond, std::function<void(bool)> done) {
  if (h->done()) return;
  if (cond()) { done(true); return; }
  if (timeoutMs <= 0) { done(false); return; }
  Later(0.1, [=] { WaitFor(h, timeoutMs - 100, cond, done); });
}
NSString* Root() { return (getenv("NOCHE_PROBE_ROOT") ? @(getenv("NOCHE_PROBE_ROOT")) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Probe"]); }
NSString* Dir(NSString* n) { return [Root() stringByAppendingPathComponent:n]; }
bool Exists(NSString* p) { return [NSFileManager.defaultManager fileExistsAtPath:p]; }
NSString* Page(const H& h, NSString* path) { return [[NSURL URLWithString:path relativeToURL:[NSURL URLWithString:h->url()]] absoluteString]; }
NSString* Localhost(NSString* u) { return [u stringByReplacingOccurrencesOfString:@"127.0.0.1" withString:@"localhost"]; }
NSString* Token() { return [NSString stringWithFormat:@"%llx", (unsigned long long)(arc4random() | ((uint64_t)arc4random() << 32))]; }
NSString* Marker(NSString* n) { return Dir([NSString stringWithFormat:@"profile-probe-%@.txt", n]); }

struct Chk {
  std::vector<std::string> failed;
  void Ok(const char* name, bool ok, NSString* detail) {
    PI(@"assert %s %s: %@", name, ok ? "PASS" : "FAIL", detail);
    if (!ok) failed.push_back(name);
  }
} g_c;

// ---- windows of other profiles ----
class CB : public CefCompletionCallback {
 public:
  explicit CB(std::function<void()> f) : f_(f) {}
  void OnComplete() override { f_(); }
 private:
  std::function<void()> f_;
  IMPLEMENT_REFCOUNTING(CB);
};
struct Win {
  CefRefPtr<CefRequestContext> ctx;
  CefRefPtr<CefWindow> window;
  CefRefPtr<CefBrowserView> view;
  std::map<int, int> load;      // browser id -> main frame load end status
  std::vector<int> created;     // browser ids in creation order (the first is the first tab)
  std::set<int> closed;         // ids whose OnBeforeClose ran
  bool destroyed = false;
  int first() const { return created.empty() ? -1 : created[0]; }
};
using WP = std::shared_ptr<Win>;
std::vector<WP> g_wins;
std::function<void(CefRefPtr<CefBrowser>)> g_observe;

// Downloads in these windows go to the harness's temp download directory (deleted on exit), never to ~/Downloads.
class PDl : public CefDownloadHandler {
 public:
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem>, const CefString& name, CefRefPtr<CefBeforeDownloadCallback> cb) override {
    const char* d = getenv("NOCHE_PROBE_DL_DIR");
    cb->Continue(std::string(d ? d : NSTemporaryDirectory().UTF8String) + "/" + name.ToString(), false);
    return true;
  }
 private:
  IMPLEMENT_REFCOUNTING(PDl);
};
class PClient : public CefClient, public CefLoadHandler, public CefLifeSpanHandler {
 public:
  explicit PClient(WP w) : w_(w) {}
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return new PDl(); }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  void OnBeforeClose(CefRefPtr<CefBrowser> b) override { w_->closed.insert(b->GetIdentifier()); }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, int status) override { if (f->IsMain()) w_->load[b->GetIdentifier()] = status; }
 private:
  WP w_;
  IMPLEMENT_REFCOUNTING(PClient);
};
class PView : public CefBrowserViewDelegate {
 public:
  explicit PView(WP w) : w_(w) {}
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  void OnBrowserCreated(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> b) override {
    w_->created.push_back(b->GetIdentifier());
    if (g_observe) g_observe(b);
  }
 private:
  WP w_;
  IMPLEMENT_REFCOUNTING(PView);
};
class PWin : public CefWindowDelegate {
 public:
  explicit PWin(WP w) : w_(w) {}
  void OnWindowCreated(CefRefPtr<CefWindow> win) override {
    w_->window = win;
    win->AddChildView(w_->view);
    NSWindow* nw = ((__bridge NSView*)win->GetWindowHandle()).window;
    nw.alphaValue = 0;
    nw.ignoresMouseEvents = YES;
  }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(160, 160, 900, 600); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { w_->destroyed = true; w_->window = nullptr; w_->view = nullptr; }
 private:
  WP w_;
  IMPLEMENT_REFCOUNTING(PWin);
};

// A hidden window whose first tab loads |url|, in |ctx| (an own context per profile; an empty cache_path context is an incognito one).
// The view is created once the context reports it is initialized: CreateBrowserView on a context that is still being created (a Chrome
// profile loads asynchronously) hits "DCHECK failed: Uninitialized context" in CefRequestContextImpl::VerifyBrowserContext and aborts.
// So w->view and w->window are null until the callback ran; every caller waits for Loaded() before it touches them.
WP Open(CefRefPtr<CefRequestContext> ctx, NSString* url) {
  auto w = std::make_shared<Win>();
  w->ctx = ctx;
  g_wins.push_back(w);
  NSString* u = [url copy];
  ctx->GetCookieManager(new CB([w, ctx, u] {
    w->view = CefBrowserView::CreateBrowserView(new PClient(w), u.UTF8String, CefBrowserSettings(), nullptr, ctx, new PView(w));
    CefWindow::CreateTopLevelWindow(new PWin(w));
  }));
  return w;
}
CefRefPtr<CefRequestContext> MakeCtx(NSString* path) {
  CefRequestContextSettings s;
  if (path.length) CefString(&s.cache_path) = path.UTF8String;
  return CefRequestContext::CreateContext(s, nullptr);
}
CefRefPtr<CefBrowser> TabOf(CefRefPtr<CefBrowserView> v, int id) {
  std::vector<CefRefPtr<CefBrowser>> t;
  if (v) v->GetTabs(t);
  for (auto& b : t) if (b->GetIdentifier() == id) return b;
  return nullptr;
}
std::vector<int> IdsOf(CefRefPtr<CefBrowserView> v) {
  std::vector<CefRefPtr<CefBrowser>> t;
  if (v) v->GetTabs(t);
  std::vector<int> ids;
  for (auto& b : t) ids.push_back(b->GetIdentifier());
  return ids;
}
bool Loaded(const WP& w, int id) { return w->load.count(id) > 0; }
// Close every window of the other profiles (the main window is closed by the run's own end), wait for them, then |then|.
void CloseAll(H h, std::function<void()> then) {
  for (auto& w : g_wins) if (w->window) w->window->Close();
  WaitFor(h, 8000, [] { for (auto& w : g_wins) if (!w->destroyed) return false; return true; }, [=](bool) {
    g_wins.clear();
    Later(0.5, then);
  });
}
void End(H h, NSString* what) {
  const bool ok = g_c.failed.empty();
  NSMutableString* d = [NSMutableString stringWithFormat:@"%@: ", what];
  if (ok) [d appendString:@"every assertion held"];
  else { [d appendString:@"FAILED assertions"]; for (auto& f : g_c.failed) [d appendFormat:@" %s", f.c_str()]; }
  CloseAll(h, [=] { h->finish(ok, d); });
}

// ---- cookies ----
class SetCB : public CefSetCookieCallback {
 public:
  explicit SetCB(std::function<void(bool)> f) : f_(f) {}
  void OnComplete(bool ok) override { f_(ok); }
 private:
  std::function<void(bool)> f_;
  IMPLEMENT_REFCOUNTING(SetCB);
};
class DelCB : public CefDeleteCookiesCallback {
 public:
  explicit DelCB(std::function<void(int)> f) : f_(f) {}
  void OnComplete(int n) override { f_(n); }
 private:
  std::function<void(int)> f_;
  IMPLEMENT_REFCOUNTING(DelCB);
};
// The visitor's destructor runs after the last cookie (and also when there is none): that is the "done" signal.
class VisC : public CefCookieVisitor {
 public:
  explicit VisC(std::function<void(std::vector<std::string>)> f) : f_(f) {}
  ~VisC() override { f_(names_); }
  bool Visit(const CefCookie& c, int, int, bool& del) override {
    names_.push_back(CefString(&c.name).ToString() + "@" + CefString(&c.domain).ToString());
    del = false;
    return true;
  }
 private:
  std::function<void(std::vector<std::string>)> f_;
  std::vector<std::string> names_;
  IMPLEMENT_REFCOUNTING(VisC);
};
CefRefPtr<CefRequestContext> Ctx(const WP& w) { return w ? w->ctx : CefRequestContext::GetGlobalContext(); }
void SetCk(CefRefPtr<CefRequestContext> ctx, NSString* url, const char* name, std::function<void(bool)> cb) {
  CefCookie c;
  CefString(&c.name) = name;
  CefString(&c.value) = "1";
  CefString(&c.path) = "/";
  c.has_expires = 1;
  c.expires = CefBaseTime::Now();
  c.expires.val += 86400LL * 1000000;
  if (!ctx->GetCookieManager(nullptr)->SetCookie(url.UTF8String, c, new SetCB(cb))) cb(false);
}
void DelAllCk(CefRefPtr<CefRequestContext> ctx, std::function<void(int)> cb) {
  if (!ctx->GetCookieManager(nullptr)->DeleteCookies("", "", new DelCB(cb))) cb(-1);
}
// FlushStore with a 6 s fallback: a flush that never reports back is printed, not a hang.
void Flush(CefRefPtr<CefRequestContext> ctx, std::function<void()> cb, const char* label = "") {
  auto holder = std::make_shared<std::function<void()>>(cb);  // emptied on the first firing, so the pending timer block keeps no context alive
  auto fire = [holder, lbl = std::string(label)](const char* how) {
    if (!*holder) return;
    auto f = std::move(*holder);
    *holder = nullptr;
    if (strcmp(how, "ok")) PI(@"FlushStore of %s: %s", lbl.c_str(), how);
    f();
  };
  if (!ctx->GetCookieManager(nullptr)->FlushStore(new CB([fire] { fire("ok"); }))) { fire("returned false (no callback)"); return; }
  Later(6.0, [fire] { fire("callback did not arrive in 6 s"); });
}
void ListCk(CefRefPtr<CefRequestContext> ctx, std::function<void(std::vector<std::string>)> cb) {
  auto mgr = ctx->GetCookieManager(nullptr);
  if (!mgr->VisitAllCookies(new VisC(cb))) cb({});
}
bool Has(const std::vector<std::string>& v, const char* name) {
  const std::string p = std::string(name) + "@";
  for (auto& s : v) if (s.compare(0, p.size(), p) == 0) return true;
  return false;
}
NSString* Join(const std::vector<std::string>& v) {
  NSMutableArray* o = [NSMutableArray array];
  for (auto& s : v) [o addObject:@(s.c_str())];
  return o.count ? [o componentsJoinedByString:@","] : @"(none)";
}
void Ev(H h, CefRefPtr<CefBrowser> b, NSString* js, bool await, std::function<void(NSString*)> cb) { h->eval(b, js, await, cb); }
// Navigates |tab|'s main frame to |url| and calls |cb| once the page there reports readyState complete (false after 20 s).
void NavWait(H h, CefRefPtr<CefBrowser> tab, NSString* url, std::function<void(bool)> cb) {
  tab->GetMainFrame()->LoadURL(url.UTF8String);
  auto tries = std::make_shared<int>(0);
  auto poll = std::make_shared<std::function<void()>>();
  *poll = [=] {
    if (h->done()) return;
    Ev(h, tab, @"document.readyState + ' ' + location.href", false, [=](NSString* r) {
      if ([r isEqualToString:[@"complete " stringByAppendingString:url]]) { *poll = nullptr; cb(true); }
      else if (++*tries > 200) { *poll = nullptr; cb(false); }
      else Later(0.1, [=] { if (*poll) (*poll)(); });
    });
  };
  Later(0.3, [=] { (*poll)(); });
}
NSString* DocCookie(NSString* r) { return r.length ? r : @"(empty)"; }
void WriteMarker(NSString* n, NSString* s) { [s writeToFile:Marker(n) atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
NSString* ReadMarker(NSString* n) { return [NSString stringWithContentsOfFile:Marker(n) encoding:NSUTF8StringEncoding error:nil] ?: @""; }

// ---- profile-dirs ----
void CheckDirs(H h) {
  NSString* p1 = Dir(@"Profile 1");
  auto c1 = MakeCtx(p1);
  PI(@"CreateContext(%@) GetCachePath right after the call: '%s'", p1, c1->GetCachePath().ToString().c_str());
  auto inited = std::make_shared<bool>(false);
  c1->GetCookieManager(new CB([inited] { *inited = true; }));
  WaitFor(h, 15000, [=] { return *inited; }, [=](bool ok) {
    g_c.Ok("context-initialized", ok, ok ? @"GetCookieManager callback ran" : @"GetCookieManager callback did not run in 15 s");
    const std::string got = c1->GetCachePath().ToString();
    g_c.Ok("cache-path-equals-requested", got == p1.UTF8String, [NSString stringWithFormat:@"GetCachePath '%s' requested '%@'", got.c_str(), p1]);
    auto w = Open(c1, Localhost(Page(h, @"index.html?side=B")));
    NSString* prefs = Dir(@"Profile 1/Preferences");
    const auto t0 = std::chrono::steady_clock::now();
    WaitFor(h, 20000, [=] { return Exists(prefs); }, [=](bool had) {
      g_c.Ok("preferences-file", had, [NSString stringWithFormat:@"%@ exists=%d after %.1f s (window open in the context)", prefs, (int)had, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count()]);
      NSString* deep = Dir(@"Profile 1/x");
      auto cd = MakeCtx(deep);
      auto dInit = std::make_shared<bool>(false);
      cd->GetCookieManager(new CB([dInit] { *dInit = true; }));
      WaitFor(h, 8000, [=] { return *dInit; }, [=](bool) {
        const std::string dgot = cd->GetCachePath().ToString();
        PI(@"deeper path %@: GetCachePath '%s' (callback ran=%d)", deep, dgot.c_str(), (int)*dInit);
        // A directory made under a loaded profile's dir is not enough: persistence means a Preferences file in it.
        Later(3.0, [=] {
          const bool prefsThere = Exists(Dir(@"Profile 1/x/Preferences"));
          g_c.Ok("deeper-path-not-a-profile", dgot.empty() || !prefsThere, [NSString stringWithFormat:@"GetCachePath '%s', Profile 1/x exists=%d, Profile 1/x/Preferences exists=%d (documents the silent in-memory fallback)", dgot.c_str(), (int)Exists(deep), (int)prefsThere]);
          NSString* outside = [NSTemporaryDirectory() stringByAppendingPathComponent:@"noche-profile-outside"];
          auto co = MakeCtx(outside);
          auto oInit = std::make_shared<bool>(false);
          co->GetCookieManager(new CB([oInit] { *oInit = true; }));
          WaitFor(h, 5000, [=] { return *oInit; }, [=](bool) {
            PI(@"path outside the root %@: GetCachePath '%s' exists=%d", outside, co->GetCachePath().ToString().c_str(), (int)Exists(outside));
            End(h, @"profile-dirs");
          });
        });
      });
    });
  });
}

// ---- profile-cookie (-2 after a relaunch) ----
void CheckCookie(H h) {
  auto cB = MakeCtx(Dir(@"Profile 1"));
  NSString* url = Localhost(Page(h, @"index.html?side=B"));
  auto w = Open(cB, url);
  auto cA = CefRequestContext::GetGlobalContext();
  NSString* origin = Localhost(h->url());
  DelAllCk(cA, [=](int) { DelAllCk(cB, [=](int) { NavWait(h, h->first(), Localhost(Page(h, @"index.html?side=A")), [=](bool aLoaded) {
    WaitFor(h, 20000, [=] { return Loaded(w, w->first()); }, [=](bool loaded) {
      g_c.Ok("both-windows-loaded", loaded && aLoaded, @"profile B window and A's localhost page loaded");
      SetCk(cA, origin, "nocheA", [=](bool okA) {
        g_c.Ok("set-cookie-A", okA, @"SetCookie in A (Default context)");
        auto tabA = h->first();
        auto tabB = TabOf(w->view, w->first());
        Ev(h, tabB, @"document.cookie", false, [=](NSString* inB) {
          Ev(h, tabA, @"document.cookie", false, [=](NSString* inA) {
            g_c.Ok("A-cookie-visible-in-A", [inA containsString:@"nocheA=1"], [NSString stringWithFormat:@"document.cookie in A: %@", DocCookie(inA)]);
            g_c.Ok("A-cookie-absent-in-B", inB.length == 0, [NSString stringWithFormat:@"document.cookie in B: %@", DocCookie(inB)]);
            SetCk(cB, origin, "nocheB", [=](bool okB) {
              g_c.Ok("set-cookie-B", okB, @"SetCookie in B (Profile 1 context)");
              Ev(h, tabB, @"document.cookie", false, [=](NSString* inB2) {
                Ev(h, tabA, @"document.cookie", false, [=](NSString* inA2) {
                  g_c.Ok("B-cookie-visible-in-B", [inB2 containsString:@"nocheB=1"] && ![inB2 containsString:@"nocheA"], [NSString stringWithFormat:@"document.cookie in B: %@", DocCookie(inB2)]);
                  g_c.Ok("B-cookie-absent-in-A", [inA2 containsString:@"nocheA=1"] && ![inA2 containsString:@"nocheB"], [NSString stringWithFormat:@"document.cookie in A: %@", DocCookie(inA2)]);
                  Flush(cA, [=] { Flush(cB, [=] {
                    WriteMarker(@"cookie", @"set");
                    End(h, @"profile-cookie (relaunch half: profile-cookie-2)");
                  }); });
                });
              });
            });
          });
        });
      });
    });
  }); }); });
}
void CheckCookie2(H h) {
  g_c.Ok("phase-1-ran", [ReadMarker(@"cookie") isEqualToString:@"set"], @"marker file from profile-cookie present");
  auto cB = MakeCtx(Dir(@"Profile 1"));
  auto cA = CefRequestContext::GetGlobalContext();
  ListCk(cA, [=](std::vector<std::string> a) { ListCk(cB, [=](std::vector<std::string> b) {
    g_c.Ok("A-keeps-cookie-after-relaunch", Has(a, "nocheA") && !Has(a, "nocheB"), [NSString stringWithFormat:@"A cookies: %@", Join(a)]);
    g_c.Ok("B-keeps-only-its-cookie-after-relaunch", Has(b, "nocheB") && !Has(b, "nocheA"), [NSString stringWithFormat:@"B cookies: %@", Join(b)]);
    DelAllCk(cA, [=](int na) { DelAllCk(cB, [=](int nb) {
      PI(@"cleanup deleted %d cookies in A, %d in B", na, nb);
      Flush(cA, [=] { Flush(cB, [=] { End(h, @"profile-cookie-2"); }, "B"); }, "A");
    }); });
  }); });
}

// ---- profile-storage ----
void CheckStorage(H h) {
  auto cB = MakeCtx(Dir(@"Profile 1"));
  NSString* url = Localhost(Page(h, @"profile-storage.html"));
  auto w = Open(cB, url);
  auto tabA = h->first();
  NavWait(h, tabA, url, [=](bool aLoaded) {
  WaitFor(h, 20000, [=] { return Loaded(w, w->first()); }, [=](bool loaded) {
    g_c.Ok("B-page-loaded", loaded && aLoaded, @"profile storage fixture loaded in B and in A");
    Later(0.5, [=] {
      auto tabB = TabOf(w->view, w->first());
      Ev(h, tabA, @"typeof window.noche === 'object' ? 'ready' : 'missing'", false, [=](NSString* ready) {
        g_c.Ok("A-page-loaded", [ready isEqualToString:@"ready"], [NSString stringWithFormat:@"fixture API in A: %@", ready]);
        Ev(h, tabA, @"window.noche.set()", true, [=](NSString* setR) {
          PI(@"A after set(): %@", setR);
          bool allSet = [setR containsString:@"\"ls\":\"fromA\""] && [setR containsString:@"nocheDb"] && [setR containsString:@"\"sw\":1"] && [setR containsString:@"nocheCache"];
          g_c.Ok("A-holds-all-four", allSet, [NSString stringWithFormat:@"A: %@", setR]);
          Ev(h, tabB, @"window.noche.get()", true, [=](NSString* getB) {
            PI(@"B get(): %@", getB);
            g_c.Ok("B-holds-none", [getB isEqualToString:@"{\"ls\":null,\"idb\":[],\"sw\":0,\"caches\":[]}"], [NSString stringWithFormat:@"B: %@ (same origin, other profile)", getB]);
            End(h, @"profile-storage");
          });
        });
      });
    });
  });
  });
}

// ---- profile-ext ----
// The command line loads fixture X (probe-extension) and fixture Y (probe-extension-b) into EVERY profile. The check removes X from B and Y from A
// with each fixture's own chrome.management.uninstallSelf, so afterwards A's registry holds only X and B's only Y, and everything below compares two
// profiles that really hold different extensions: B has no entry for X and no X action, A none for Y, chrome.tabs in each only lists its own window.
#ifdef NOCHE_ACTIONS_API
const char* kNameX = "Noche engine probe extension";
const char* kNameY = "Noche second probe extension";
struct ActObs : CefExtensionActionObserver {
  int xUpdates = 0, yUpdates = 0;
  void OnActionUpdated(CefRefPtr<CefExtensionAction> a) override {
    if (!a) return;
    const std::string n = a->GetName().ToString();
    if (n == kNameX) xUpdates++; else if (n == kNameY) yUpdates++;
  }
  IMPLEMENT_REFCOUNTING(ActObs);
};
std::string ActionNames(CefRefPtr<CefBrowserView> v) {
  std::vector<CefRefPtr<CefExtensionAction>> all;
  if (v) v->GetExtensionActions(all);
  std::vector<std::string> n;
  for (auto& a : all) n.push_back(a->GetName().ToString());
  std::sort(n.begin(), n.end());
  std::string s;
  for (auto& x : n) s += (s.empty() ? "" : "|") + x;
  return s.empty() ? "(none)" : s;
}
std::string BadgeOf(CefRefPtr<CefBrowserView> v, CefRefPtr<CefBrowser> tab, const char* name) {
  std::vector<CefRefPtr<CefExtensionAction>> all;
  if (v) v->GetExtensionActions(all);
  for (auto& a : all) if (a->GetName().ToString() == name) return a->GetBadgeText(tab).ToString();
  return "(no action)";
}
#endif

// One command in the service worker of fixture X (second=false) or Y (second=true) behind |tab| (the content script relays 'noche-cmd' / 'noche-cmd-b').
void ExtOn(H h, CefRefPtr<CefBrowser> tab, NSDictionary* cmd, bool second, std::function<void(NSDictionary*)> cb) {
  if (!tab) { cb(@{@"error" : @"no tab"}); return; }
  NSData* json = [NSJSONSerialization dataWithJSONObject:@[ [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:cmd options:0 error:nil] encoding:NSUTF8StringEncoding] ] options:0 error:nil];
  NSString* arr = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
  NSString* evt = second ? @"noche-cmd-b" : @"noche-cmd";
  NSString* key = second ? @"nocheReplyB" : @"nocheReply";
  NSString* js = [NSString stringWithFormat:@"delete document.documentElement.dataset.%@; document.dispatchEvent(new CustomEvent('%@', {detail: %@[0]})); 'sent'", key, evt, arr];
  NSString* readJs = [NSString stringWithFormat:@"document.documentElement.dataset.%@ || ''", key];
  auto tries = std::make_shared<int>(0);
  auto poll = std::make_shared<std::function<void()>>();
  *poll = [=] {
    if (h->done()) return;
    Ev(h, tab, readJs, false, [=](NSString* r) {
      if (r.length) {
        NSDictionary* j = [NSJSONSerialization JSONObjectWithData:[r dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        *poll = nullptr;
        cb([j isKindOfClass:NSDictionary.class] ? j : @{@"error" : r});
      } else if (++*tries > 100) {
        *poll = nullptr;
        cb(@{@"error" : @"no answer from the service worker in 10 s"});
      } else {
        Later(0.1, [=] { if (*poll) (*poll)(); });
      }
    });
  };
  Ev(h, tab, js, false, [=](NSString*) { (*poll)(); });
}
NSString* TabUrlsOf(NSDictionary* j) {
  NSMutableArray* o = [NSMutableArray array];
  for (NSDictionary* t in j[@"tabs"]) [o addObject:[NSString stringWithFormat:@"%@", t[@"url"]]];
  return [o componentsJoinedByString:@" "];
}
int CountSide(NSDictionary* j, NSString* side) {
  int n = 0;
  for (NSDictionary* t in j[@"tabs"]) if ([[NSString stringWithFormat:@"%@", t[@"url"]] containsString:side]) n++;
  return n;
}
// "x/y": which fixture content scripts ran on the page ("1" or "-").
void Mark(H h, CefRefPtr<CefBrowser> tab, std::function<void(NSString*)> cb) {
  Ev(h, tab, @"(document.documentElement.dataset.nocheExt || '-') + '/' + (document.documentElement.dataset.nocheExtB || '-')", false, cb);
}

void CheckExt(H h) {
#ifndef NOCHE_ACTIONS_API
  g_c.Ok("actions-api", false, @"built without NOCHE_ACTIONS_API");
  End(h, @"profile-ext");
#else
  auto cB = MakeCtx(Dir(@"Profile 1"));
  auto w = Open(cB, Localhost(Page(h, @"index.html?side=B&n=1")));
  auto tabA1 = h->first();
  auto tabA2 = h->view()->AddTab(Page(h, @"index.html?side=A&n=2").UTF8String, nullptr, CefBrowserSettings(), nullptr, false);
  tabA1->GetMainFrame()->LoadURL(Page(h, @"index.html?side=A&n=1").UTF8String);
  WaitFor(h, 20000, [=] { return Loaded(w, w->first()); }, [=](bool loaded) {
    auto bFirst = TabOf(w->view, w->first());
    auto b2 = w->view->AddTab(Localhost(Page(h, @"index.html?side=B&n=2")).UTF8String, nullptr, CefBrowserSettings(), nullptr, false);
    auto b3 = w->view->AddTab(Localhost(Page(h, @"index.html?side=B&n=3")).UTF8String, nullptr, CefBrowserSettings(), nullptr, false);
    g_c.Ok("windows-set-up", loaded && tabA2 && b2 && b3 && w->view->GetTabCount() == 3 && h->view()->GetTabCount() == 2, [NSString stringWithFormat:@"B tabs %zu (want 3), A tabs %zu (want 2)", w->view->GetTabCount(), h->view()->GetTabCount()]);
    Later(3.0, [=] {
      Mark(h, tabA1, [=](NSString* mA) { Mark(h, bFirst, [=](NSString* mB) {
        PI(@"before removal: content scripts in A first tab %@, in B first tab %@ (X/Y); actions A=%s B=%s", mA, mB, ActionNames(h->view()).c_str(), ActionNames(w->view).c_str());
        g_c.Ok("premise-both-fixtures-in-both-profiles", [mA isEqualToString:@"1/1"] && [mB isEqualToString:@"1/1"], [NSString stringWithFormat:@"content scripts X/Y: A %@, B %@ (the command line loads both fixtures into every profile)", mA, mB]);
        CefRefPtr<ActObs> obsA = new ActObs(), obsB = new ActObs();
        h->view()->AddExtensionActionObserver(obsA);
        w->view->AddExtensionActionObserver(obsB);
        // Remove X from B and Y from A, each through the fixture's own uninstallSelf.
        ExtOn(h, bFirst, @{@"what" : @"uninstallSelf"}, false, [](NSDictionary*) {});
        ExtOn(h, tabA1, @{@"what" : @"uninstallSelf"}, true, [](NSDictionary*) {});
        WaitFor(h, 20000, [=] { return ActionNames(h->view()) == kNameX && ActionNames(w->view) == kNameY; }, [=](bool removed) {
          const std::string na = ActionNames(h->view()), nb = ActionNames(w->view);
          g_c.Ok("A-registry-has-only-X", na == kNameX, [NSString stringWithFormat:@"A toolbar actions after Y's uninstallSelf: %s", na.c_str()]);
          g_c.Ok("B-registry-has-only-Y-no-X-entry", nb == kNameY, [NSString stringWithFormat:@"B toolbar actions after X's uninstallSelf: %s (an empty or Y-only list: X has no entry in B)", nb.c_str()]);
          if (!removed) PI(@"uninstallSelf did not remove the fixture in 20 s (it may be refused for a command-line loaded extension); the isolation assertions below compare profiles that still hold both fixtures");
          obsA->xUpdates = obsA->yUpdates = obsB->xUpdates = obsB->yUpdates = 0;
          // Fresh pages: only the remaining fixture's content script runs in each profile.
          NavWait(h, tabA2, Page(h, @"index.html?side=A&n=2&nav=1"), [=](bool nA) { NavWait(h, b2, Localhost(Page(h, @"index.html?side=B&n=2&nav=1")), [=](bool nB) {
            Mark(h, tabA2, [=](NSString* m2A) { Mark(h, b2, [=](NSString* m2B) {
              g_c.Ok("content-scripts-per-profile", nA && nB && [m2A isEqualToString:@"1/-"] && [m2B isEqualToString:@"-/1"], [NSString stringWithFormat:@"content scripts X/Y on a fresh A page %@ (want 1/-), on a fresh B page %@ (want -/1)", m2A, m2B]);
              ExtOn(h, tabA2, @{@"what" : @"tabsinfo"}, false, [=](NSDictionary* ta) { ExtOn(h, b2, @{@"what" : @"tabsinfo"}, true, [=](NSDictionary* tb) {
                PI(@"X chrome.tabs.query in A: %@ ; Y chrome.tabs.query in B: %@", ta[@"error"] ?: TabUrlsOf(ta), tb[@"error"] ?: TabUrlsOf(tb));
                g_c.Ok("A-tabs-query-lists-only-A", !ta[@"error"] && [ta[@"tabs"] count] == 2 && CountSide(ta, @"side=A") == 2 && CountSide(ta, @"side=B") == 0, [NSString stringWithFormat:@"X in A sees %lu tabs: %d of A, %d of B", (unsigned long)[ta[@"tabs"] count], CountSide(ta, @"side=A"), CountSide(ta, @"side=B")]);
                g_c.Ok("B-tabs-query-never-returns-A-tab", !tb[@"error"] && [tb[@"tabs"] count] == 3 && CountSide(tb, @"side=B") == 3 && CountSide(tb, @"side=A") == 0, [NSString stringWithFormat:@"Y in B sees %lu tabs: %d of B, %d of A", (unsigned long)[tb[@"tabs"] count], CountSide(tb, @"side=B"), CountSide(tb, @"side=A")]);
                ExtOn(h, tabA2, @{@"what" : @"windowNormal"}, false, [=](NSDictionary* wa) { ExtOn(h, b2, @{@"what" : @"windowNormal"}, true, [=](NSDictionary* wb) {
                  NSArray* wsa = wa[@"wins"]; NSArray* wsb = wb[@"wins"];
                  PI(@"X windows in A: %@ ; Y windows in B: %@", wa[@"error"] ?: wsa, wb[@"error"] ?: wsb);
                  g_c.Ok("window-identity-per-profile", wsa.count == 1 && wsb.count == 1 && [wsa[0][@"tabs"] intValue] == 2 && [wsb[0][@"tabs"] intValue] == 3 && ![wsa[0][@"id"] isEqual:wsb[0][@"id"]] && [wsa[0][@"type"] isEqual:@"normal"] && [wsb[0][@"type"] isEqual:@"normal"], [NSString stringWithFormat:@"A: %lu normal window(s) with %@ tabs, id %@; B: %lu with %@ tabs, id %@ (want 1 and 2, 1 and 3, ids differ)", (unsigned long)wsa.count, wsa.count ? wsa[0][@"tabs"] : @"-", wsa.count ? wsa[0][@"id"] : @"-", (unsigned long)wsb.count, wsb.count ? wsb[0][@"tabs"] : @"-", wsb.count ? wsb[0][@"id"] : @"-"]);
                  // Badges: X's badge set in A must not appear in B (no X action there), Y's set in B not in A.
                  ExtOn(h, tabA2, @{@"what" : @"badge", @"text" : @"A", @"color" : @"#112233"}, false, [=](NSDictionary*) { ExtOn(h, b2, @{@"what" : @"badge", @"text" : @"B", @"color" : @"#332211"}, true, [=](NSDictionary*) {
                    Later(1.5, [=] {
                      const std::string xa = BadgeOf(h->view(), tabA2, kNameX), yb = BadgeOf(w->view, b2, kNameY), xb = BadgeOf(w->view, b2, kNameX), ya = BadgeOf(h->view(), tabA2, kNameY);
                      PI(@"badges: X in A '%s', Y in B '%s', X in B '%s', Y in A '%s'; observer updates: A saw X=%d Y=%d, B saw X=%d Y=%d", xa.c_str(), yb.c_str(), xb.c_str(), ya.c_str(), obsA->xUpdates, obsA->yUpdates, obsB->xUpdates, obsB->yUpdates);
                      g_c.Ok("badges-stay-in-their-profile", xa == "A" && yb == "B" && xb == "(no action)" && ya == "(no action)" && obsA->xUpdates >= 1 && obsB->yUpdates >= 1 && obsB->xUpdates == 0 && obsA->yUpdates == 0, [NSString stringWithFormat:@"X in A '%s', Y in B '%s', X in B '%s', Y in A '%s'; B observer updates for X %d, A observer updates for Y %d (want 0)", xa.c_str(), yb.c_str(), xb.c_str(), ya.c_str(), obsB->xUpdates, obsA->yUpdates]);
                      PI(@"install in B and the dialog's anchor window (patch 0004): NOT RUN by this check; see the report (no hidden-run install path reaches ExtensionInstallUIDesktop; owner check)");
                      End(h, @"profile-ext");
                    });
                  }); });
                }); });
              }); });
            }); });
          }); });
        });
      }); });
    });
  });
#endif
}

// ---- profile-close ----
double Median(std::vector<double> v) { if (v.empty()) return -1; std::sort(v.begin(), v.end()); return v[v.size() / 2]; }
// 10 tab switches in A, each followed by one eval round trip on the new active tab: milliseconds per switch+round trip.
void SwitchTimes(H h, std::function<void(double)> cb) {
  auto samples = std::make_shared<std::vector<double>>();
  auto step = std::make_shared<std::function<void(int)>>();
  *step = [=](int i) {
    if (i == 10) { auto f = cb; const double m = Median(*samples); Later(0, [step] { *step = nullptr; }); f(m); return; }  // not from inside the closure that is running
    auto v = h->view();
    auto ids = IdsOf(v);
    if (ids.size() < 2) { auto f = cb; Later(0, [step] { *step = nullptr; }); f(-1); return; }
    auto b = TabOf(v, ids[i % 2]);
    const auto t0 = std::chrono::steady_clock::now();
    v->SetActiveTab(b);
    Ev(h, b, @"1+1", false, [=](NSString*) {
      samples->push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
      Later(0.05, [=] { (*step)(i + 1); });
    });
  };
  (*step)(0);
}
// A main document whose response the fixture server (slow_server.py /hold.html) keeps open: the tab stays loading until the connection closes.
NSString* HoldUrl(NSString* q) {
  const char* s = getenv("NOCHE_PROBE_SLOW_URL");
  return [(s ? @(s) : @"") stringByReplacingOccurrencesOfString:@"big.bin" withString:[@"hold.html?" stringByAppendingString:q]];
}
// IsLoading of every tab of |v|, as "id=1 id=1"; all is true when there is at least |min| tab and each is loading.
NSString* LoadingFacts(CefRefPtr<CefBrowserView> v, size_t min, bool* all) {
  std::vector<CefRefPtr<CefBrowser>> t;
  if (v) v->GetTabs(t);
  NSMutableArray* o = [NSMutableArray array];
  bool every = t.size() >= min;
  for (auto& b : t) { [o addObject:[NSString stringWithFormat:@"%d=%d", b->GetIdentifier(), (int)b->IsLoading()]]; if (!b->IsLoading()) every = false; }
  *all = every;
  return [o componentsJoinedByString:@" "];
}
// Sends every tab of |v| to a hold page and waits until each reports IsLoading.
void HoldAll(H h, CefRefPtr<CefBrowserView> v, NSString* tag, std::function<void(bool, NSString*)> cb) {
  int n = 0;
  for (int id : IdsOf(v)) TabOf(v, id)->GetMainFrame()->LoadURL(HoldUrl([NSString stringWithFormat:@"%@%d", tag, n++]).UTF8String);
  auto last = std::make_shared<NSString*>(@"");
  const size_t want = IdsOf(v).size();
  WaitFor(h, 15000, [=] { bool all = false; *last = LoadingFacts(v, want, &all); return all; }, [=](bool ok) { cb(ok, *last); });
}

void CloseProfile(H h);
void CheckClose(H h) {
  auto cB = std::make_shared<CefRefPtr<CefRequestContext>>(MakeCtx(Dir(@"Profile 1")));
  NSString* origin = Localhost(h->url());
  auto wB = std::make_shared<WP>(Open(*cB, Localhost(Page(h, @"index.html?side=B"))));
  auto tabA2 = h->view()->AddTab(Page(h, @"index.html?side=A&n=2").UTF8String, nullptr, CefBrowserSettings(), nullptr, false);
  DelAllCk(*cB, [=](int) {
    WaitFor(h, 20000, [=] { return Loaded(*wB, (*wB)->first()) && tabA2; }, [=](bool loaded) {
      g_c.Ok("windows-loaded", loaded, @"B first tab loaded, A has two tabs");
      SetCk(*cB, origin, "nocheB", [=](bool ok) {
        g_c.Ok("set-cookie-B", ok, @"cookie in B");
        Flush(*cB, [=] {
          SwitchTimes(h, [=](double before) {
            PI(@"A switch+round trip median before (A idle): %.1f ms", before);
            // Both A tabs now sit on a main document the server holds open: they must be loading when B closes.
            HoldAll(h, h->view(), @"a", [=](bool holding, NSString* facts) {
              g_c.Ok("A-two-tabs-loading-before-B-closes", holding, [NSString stringWithFormat:@"A tabs IsLoading (id=value): %@ (hold page held open by the fixture server)", facts]);
              auto closeIds = std::make_shared<std::vector<int>>((*wB)->created);
              (*wB)->window->Close();
              WaitFor(h, 10000, [=] { return (*wB)->destroyed; }, [=](bool destroyed) {
                bool allClosed = true;
                for (int id : *closeIds) if (!(*wB)->closed.count(id)) allClosed = false;
                g_c.Ok("B-closed-callbacks", destroyed && allClosed, [NSString stringWithFormat:@"window destroyed=%d, OnBeforeClose for %zu of %zu B browsers", (int)destroyed, (*wB)->closed.size(), closeIds->size()]);
                // Release every reference to profile B: window, view, context.
                g_wins.clear(); *wB = nullptr; *cB = nullptr;
                Ev(h, h->first(), @"'alive:' + (1+1)", false, [=](NSString* r) {
                  bool allLoading = false;
                  NSString* f2 = LoadingFacts(h->view(), 2, &allLoading);
                  g_c.Ok("A-interactive-and-still-loading-after-B-closed", [r isEqualToString:@"alive:2"] && allLoading, [NSString stringWithFormat:@"A eval round trip '%@'; A tabs IsLoading: %@", r, f2]);
                  Later(3.0, [=] {
                    SwitchTimes(h, [=](double after) {
                      PI(@"A switch+round trip median after (A loading): %.1f ms (before %.1f ms)", after, before);
                      g_c.Ok("A-switch-latency-unchanged", before > 0 && after > 0 && after <= before * 3 + 30, [NSString stringWithFormat:@"median before %.1f ms, after %.1f ms (limit 3x + 30 ms, eval round trip includes noise)", before, after]);
                      // Reopen B: the profile loads again from disk and keeps its cookie.
                      auto cB2 = MakeCtx(Dir(@"Profile 1"));
                      auto w2 = Open(cB2, Localhost(Page(h, @"index.html?side=B&reopen=1")));
                      WaitFor(h, 20000, [=] { return Loaded(w2, w2->first()); }, [=](bool l2) {
                        Ev(h, TabOf(w2->view, w2->first()), @"document.cookie", false, [=](NSString* ck) {
                          g_c.Ok("B-reopened-keeps-cookie", l2 && [ck containsString:@"nocheB=1"], [NSString stringWithFormat:@"reopened B document.cookie: %@", DocCookie(ck)]);
                          CloseProfile(h);
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
// Second direction: close the main window (profile Default, A) while B has two tabs whose main documents are held open.
void CloseProfile(H h) {
  WP w = g_wins.back();
  w->view->AddTab(Localhost(Page(h, @"index.html?side=B&n=2")).UTF8String, nullptr, CefBrowserSettings(), nullptr, true);
  Later(1.5, [=] {
    HoldAll(h, w->view, @"b", [=](bool holding, NSString* facts) {
      g_c.Ok("B-two-tabs-loading-before-A-closes", holding, [NSString stringWithFormat:@"B tabs IsLoading (id=value): %@ (hold page held open by the fixture server)", facts]);
      std::vector<int> aIds = IdsOf(h->view());
      PI(@"closing the main window (A, %zu tabs) while B has %zu loading tabs", aIds.size(), w->view->GetTabCount());
      h->closeMain();
      WaitFor(h, 10000, [=] { return h->mainGone(); }, [=](bool gone) {
        auto bc = h->beforeClose();
        bool all = true;
        for (int id : aIds) if (!bc.count(id)) all = false;
        g_c.Ok("A-closed-callbacks", gone && all && !aIds.empty(), [NSString stringWithFormat:@"A window destroyed=%d, OnBeforeClose for all %zu A browsers=%d", (int)gone, aIds.size(), (int)all]);
        auto active = w->view->GetActiveTab();
        Ev(h, active, @"'alive:' + (1+1)", false, [=](NSString* r) {
          bool stillLoading = false;
          NSString* f2 = LoadingFacts(w->view, 2, &stillLoading);
          g_c.Ok("B-interactive-and-still-loading-after-A-closed", [r isEqualToString:@"alive:2"] && stillLoading, [NSString stringWithFormat:@"B eval round trip '%@'; B tabs IsLoading: %@", r, f2]);
          Later(2.0, [=] {
            ListCk(w->ctx, [=](std::vector<std::string> b) {
              g_c.Ok("B-still-has-cookie", Has(b, "nocheB"), [NSString stringWithFormat:@"B cookies two seconds later (cookie manager, the pages are on the hold origin): %@", Join(b)]);
              End(h, @"profile-close");
            });
          });
        });
      });
    });
  });
}

// ---- profile-incognito (-2 after a relaunch) ----
std::string Sqlite(NSString* dbCopy, NSString* q) {
  std::string cmd = std::string("sqlite3 '") + dbCopy.UTF8String + "' \"" + q.UTF8String + "\" 2>&1";
  std::string out;
  if (FILE* f = popen(cmd.c_str(), "r")) { char b[256]; while (fgets(b, sizeof b, f)) out += b; pclose(f); }
  while (!out.empty() && (out.back() == '\n' || out.back() == ' ')) out.pop_back();
  return out;
}
// A copy of Default/History with its journal files (the engine has it open), then the count of urls rows matching |like|.
// The count a query gives on a copy of <profile dir>/<db> with its journal files (-1 on an error or a missing database).
int DbCount(NSString* profileDir, NSString* db, NSString* sql) {
  NSString* tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"noche-db-" stringByAppendingString:Token()]];
  [NSFileManager.defaultManager createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
  for (NSString* suffix in @[ @"", @"-journal", @"-wal", @"-shm" ]) {
    NSString* f = [db stringByAppendingString:suffix];
    [NSFileManager.defaultManager copyItemAtPath:Dir([NSString stringWithFormat:@"%@/%@", profileDir, f]) toPath:[tmp stringByAppendingPathComponent:f] error:nil];
  }
  std::string r = Sqlite([tmp stringByAppendingPathComponent:db], sql);
  [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
  char* end = nullptr;
  long n = strtol(r.c_str(), &end, 10);
  return (end && *end == 0 && !r.empty()) ? (int)n : -1;
}
int HistoryRowsIn(NSString* profileDir, NSString* like) { return DbCount(profileDir, @"History", [NSString stringWithFormat:@"select count(*) from urls where url like '%%%@%%'", like]); }
int HistoryRows(NSString* like) { return HistoryRowsIn(@"Default", like); }
int DownloadRowsIn(NSString* profileDir, NSString* like) { return DbCount(profileDir, @"History", [NSString stringWithFormat:@"select count(*) from downloads_url_chains where url like '%%%@%%'", like]); }
int PwRows(NSString* profileDir, NSString* user) { return DbCount(profileDir, @"Login Data", [NSString stringWithFormat:@"select count(*) from logins where username_value='%@'", user]); }
int FormRowsIn(NSString* profileDir, NSString* like) { return DbCount(profileDir, @"Web Data", [NSString stringWithFormat:@"select count(*) from autocomplete where value like '%%%@%%'", like]); }
void CheckIncognito(H h) {
  NSString* tok = Token();
  NSString* origin = Localhost(h->url());
  auto cA = CefRequestContext::GetGlobalContext();
  auto cI = std::make_shared<CefRefPtr<CefRequestContext>>(MakeCtx(@""));
  g_c.Ok("incognito-cache-path-empty", (*cI)->GetCachePath().ToString().empty(), [NSString stringWithFormat:@"GetCachePath '%s'", (*cI)->GetCachePath().ToString().c_str()]);
  DelAllCk(cA, [=](int) { NavWait(h, h->first(), Localhost(Page(h, [NSString stringWithFormat:@"index.html?norm=%@", tok])), [=](bool aLoaded) {
    SetCk(cA, origin, "nocheA", [=](bool okA) {
      g_c.Ok("set-cookie-A", okA && aLoaded, @"cookie in A, A visited the normal page");
      auto wI = std::make_shared<WP>(Open(*cI, Localhost(Page(h, [NSString stringWithFormat:@"index.html?incog=%@", tok]))));
      WaitFor(h, 20000, [=] { return Loaded(*wI, (*wI)->first()); }, [=](bool loaded) {
        g_c.Ok("incognito-window-loaded", loaded, @"incognito window loaded");
        Ev(h, TabOf((*wI)->view, (*wI)->first()), @"document.cookie", false, [=](NSString* inI) {
          g_c.Ok("A-cookie-invisible-in-incognito", inI.length == 0, [NSString stringWithFormat:@"incognito document.cookie: %@", DocCookie(inI)]);
          SetCk(*cI, origin, "nocheI", [=](bool okI) {
            Ev(h, TabOf((*wI)->view, (*wI)->first()), @"document.cookie", false, [=](NSString* inI2) {
              Ev(h, h->first(), @"document.cookie", false, [=](NSString* inA) {
                g_c.Ok("incognito-cookie-visible-in-incognito", okI && [inI2 containsString:@"nocheI=1"], [NSString stringWithFormat:@"incognito document.cookie: %@", DocCookie(inI2)]);
                g_c.Ok("incognito-cookie-absent-in-A", [inA containsString:@"nocheA=1"] && ![inA containsString:@"nocheI"], [NSString stringWithFormat:@"A document.cookie: %@", DocCookie(inA)]);
                (*wI)->window->Close();
                WaitFor(h, 10000, [=] { return (*wI)->destroyed; }, [=](bool) {
                  g_wins.clear(); *wI = nullptr; *cI = nullptr;
                  Later(2.0, [=] {
                    auto cI2 = MakeCtx(@"");
                    auto w2 = Open(cI2, Localhost(Page(h, @"index.html?incog2=1")));
                    WaitFor(h, 20000, [=] { return Loaded(w2, w2->first()); }, [=](bool) {
                      Ev(h, TabOf(w2->view, w2->first()), @"document.cookie", false, [=](NSString* ck) {
                        g_c.Ok("incognito-cookie-gone-after-window-closed", ck.length == 0, [NSString stringWithFormat:@"a new empty-path context's document.cookie: %@", DocCookie(ck)]);
                        Flush(cA, [=] {
                          WriteMarker(@"incognito", tok);
                          End(h, @"profile-incognito (relaunch half: profile-incognito-2)");
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
  }); });
}
void CheckIncognito2(H h) {
  NSString* tok = ReadMarker(@"incognito");
  g_c.Ok("phase-1-ran", tok.length > 0, @"marker file from profile-incognito present");
  auto cI = MakeCtx(@"");
  auto w = Open(cI, Localhost(Page(h, @"index.html?incog3=1")));
  auto cA = CefRequestContext::GetGlobalContext();
  WaitFor(h, 20000, [=] { return Loaded(w, w->first()); }, [=](bool) {
    Ev(h, TabOf(w->view, w->first()), @"document.cookie", false, [=](NSString* ck) {
      g_c.Ok("incognito-cookie-absent-after-relaunch", ck.length == 0, [NSString stringWithFormat:@"incognito document.cookie: %@", DocCookie(ck)]);
      ListCk(cA, [=](std::vector<std::string> a) {
        g_c.Ok("A-cookie-persisted-incognito-cookie-not", Has(a, "nocheA") && !Has(a, "nocheI"), [NSString stringWithFormat:@"A cookies after relaunch: %@", Join(a)]);
        const int norm = HistoryRows([@"norm=" stringByAppendingString:tok]), incog = HistoryRows([@"incog=" stringByAppendingString:tok]);
        g_c.Ok("history-positive-control", norm >= 1, [NSString stringWithFormat:@"urls rows for the normal A visit norm=%@: %d (control: the query can see rows)", tok, norm]);
        g_c.Ok("history-has-no-incognito-visit", incog == 0, [NSString stringWithFormat:@"urls rows for the incognito visit incog=%@: %d", tok, incog]);
        DelAllCk(cA, [=](int n) { PI(@"cleanup deleted %d cookies in A", n); Flush(cA, [=] { End(h, @"profile-incognito-2"); }); });
      });
    });
  });
}

// ---- profile-clear ----
#ifdef NOCHE_CLEAR_API
void ClearRanges(H h, NSString* tok, WP wB, CefRefPtr<CefRequestContext> cB, NSString* uB);
void ClearChrome(H h, NSString* tok, CefRefPtr<CefRequestContext> cB, bool formMade, bool pwSeeded, std::function<void()> next);
#endif
NSString* SlowFile(NSString* name) {
  const char* s = getenv("NOCHE_PROBE_SLOW_URL");
  return [(s ? @(s) : @"") stringByReplacingOccurrencesOfString:@"big.bin" withString:name];
}
// Polls |query| once a second (up to |ms|) until |ok| holds on its value; |done| gets the last value.
void PollCount(H h, int ms, std::function<int()> query, std::function<bool(int)> ok, std::function<void(bool, int)> done) {
  auto last = std::make_shared<int>(-2);
  WaitFor(h, ms, [=] { *last = query(); return ok(*last); }, [=](bool good) { done(good, *last); });
}
// Creates Chrome-layer data in profile B (and a history row in A) through hidden windows only, then proves the databases show it, so a later
// "cleared" reading means something. B: a visited page (History urls), a finished download of small.bin (History downloads_url_chains), a submitted text
// form (Web Data autocomplete; may not be creatable hidden: reported, not asserted). Saved passwords cannot be created hidden (the save is a Chrome
// bubble that needs user interaction), so the PASSWORDS bit stays source-read only. These witnesses run on every engine; the clearing runs with NOCHE_CLEAR_API.
void ChromeWitness(H h, NSString* tok, WP wB, CefRefPtr<CefRequestContext> cB, std::function<void(bool, bool)> next) {
  NSString* like = [@"histB=" stringByAppendingString:tok];
  NSString* likeA = [@"histA=" stringByAppendingString:tok];
  auto bVisit = wB->view->AddTab(Localhost(Page(h, [NSString stringWithFormat:@"index.html?%@", like])).UTF8String, nullptr, CefBrowserSettings(), nullptr, false);
  h->view()->AddTab(Page(h, [NSString stringWithFormat:@"index.html?%@", likeA]).UTF8String, nullptr, CefBrowserSettings(), nullptr, false);
  wB->view->AddTab(SlowFile(@"small.bin").UTF8String, nullptr, CefBrowserSettings(), nullptr, false);
  auto form = wB->view->AddTab(Localhost(Page(h, @"profile-form.html")).UTF8String, nullptr, CefBrowserSettings(), nullptr, false);
  (void)bVisit;
  Later(4.0, [=] {
    NSString* typed = [@"noche-form-" stringByAppendingString:tok];
    Ev(h, form, @"document.getElementById('q').focus(); document.activeElement.id", false, [=](NSString* focused) {
      h->cdp(form, @"Input.insertText", @{@"text" : typed}, [=](NSDictionary*) {
        Ev(h, form, @"document.getElementById('f').requestSubmit(); 'submitted'", false, [=](NSString*) {
          PI(@"form fixture: focused '%@', typed '%@' and submitted", focused, typed);
          PollCount(h, 40000, [=] { return HistoryRowsIn(@"Profile 1", like); }, [](int n) { return n >= 1; }, [=](bool okB, int nB) {
            g_c.Ok("history-witness-B", okB, [NSString stringWithFormat:@"Profile 1/History urls rows for %@: %d", like, nB]);
            PollCount(h, 40000, [=] { return HistoryRowsIn(@"Default", likeA); }, [](int n) { return n >= 1; }, [=](bool okA, int nA) {
              g_c.Ok("history-witness-A", okA, [NSString stringWithFormat:@"Default/History urls rows for %@: %d", likeA, nA]);
              PollCount(h, 40000, [=] { return DownloadRowsIn(@"Profile 1", @"small.bin"); }, [](int n) { return n >= 1; }, [=](bool okD, int nD) {
                g_c.Ok("download-witness-B", okD, [NSString stringWithFormat:@"Profile 1/History downloads_url_chains rows for small.bin: %d (the download ran through B's client handler into the temp dir)", nD]);
                PollCount(h, 30000, [=] { return FormRowsIn(@"Profile 1", tok); }, [](int n) { return n >= 1; }, [=](bool okF, int nF) {
                  PI(@"form data witness: Profile 1/Web Data autocomplete rows for %@: %d, %s", tok, nF, okF ? "created hidden: the FORM_DATA clear is asserted" : "NOT created in a hidden run (the programmatic submit was not recorded as a user entry): FORM_DATA is source-read only here, no assertion");
                  // Passwords: ProfilesPreEngine seeded one logins row per profile before CefInitialize; prove the engine kept them.
                  const int pwB = PwRows(@"Profile 1", @"nochetest-B"), pwA = PwRows(@"Default", @"nochetest-A");
                  g_c.Ok("password-witness-seeded-rows-survive-startup", pwB >= 1 && pwA >= 1, [NSString stringWithFormat:@"logins rows after engine start: Profile 1 'nochetest-B' %d, Default 'nochetest-A' %d (want >= 1 each; the rows were inserted into Login Data files before CefInitialize)", pwB, pwA]);
                  next(okF, pwB >= 1 && pwA >= 1);
                });
              });
            });
          });
        });
      });
    });
  });
}

// Basic-auth witness for ClearHttpAuthCredentials (profile Default). Tab 1 opens /auth: the server answers 401, the client's GetAuthCredentials supplies noche:probe,
// the retry carries Authorization. A second navigation then reaches the server already with Authorization (the auth cache). After ClearHttpAuthCredentials the
// next navigation must reach the server WITHOUT Authorization again. The server's request log is the witness, not the engine.
struct AuthSt { CefRefPtr<RlRecorder> rec; CefRefPtr<RlClient> cl; int tab = -1; std::string url, credUrl; size_t seen = 0; bool cached = false; bool tabAlive = false; };
std::vector<std::string> AuthLines() {
  std::vector<std::string> o;
  NSString* l = [NSString stringWithContentsOfFile:@(getenv("NOCHE_PROBE_SLOW_LOG") ?: "/dev/null") encoding:NSUTF8StringEncoding error:nil] ?: @"";
  for (NSString* line in [l componentsSeparatedByString:@"\n"]) if ([line hasPrefix:@"/auth auth="]) o.push_back(line.UTF8String);
  return o;
}
CefRefPtr<CefBrowser> AuthTab(H h, const std::shared_ptr<AuthSt>& st) { return TabOf(h->view(), st->tab); }
void AuthNav(H h, std::shared_ptr<AuthSt> st, std::function<void(bool)> cb) {  // navigates the auth tab and waits for its load end
  const int want = st->cl->loads + 1;
  if (auto t = AuthTab(h, st)) t->GetMainFrame()->LoadURL(st->url);
  WaitFor(h, 15000, [=] { return st->cl->loads >= want; }, cb);
}
void AuthPrime(H h, std::function<void(std::shared_ptr<AuthSt>)> cb) {
  auto st = std::make_shared<AuthSt>();
  st->rec = new RlRecorder(); st->rec->answerAuth = true;
  st->cl = new RlClient(st->rec, nullptr);
  st->url = SlowFile(@"auth").UTF8String;
  st->credUrl = [SlowFile(@"auth") stringByReplacingOccurrencesOfString:@"http://" withString:@"http://noche:probe@"].UTF8String;  // the client supplies the credentials in the URL: a Chrome-style tab never asked GetAuthCredentials
  const size_t log0 = AuthLines().size();
  auto b = h->view()->AddTab(st->credUrl, st->cl, CefBrowserSettings(), nullptr, false);
  st->tab = b ? b->GetIdentifier() : -1;
  WaitFor(h, 15000, [=] { return st->cl->loads >= 1; }, [=](bool first) {
    auto after1 = AuthLines();
    const size_t k = after1.size();
    g_c.Ok("auth-first-request-challenged-then-credentialed", first && k >= log0 + 2 && after1[log0] == "/auth auth=no" && after1.back() == "/auth auth=yes", [NSString stringWithFormat:@"server log /auth lines %zu..%zu: first '%s', last '%s'; credentials sent in the URL (GetAuthCredentials answered %d time(s))", log0, k, k > log0 ? after1[log0].c_str() : "(none)", k ? after1.back().c_str() : "(none)", st->rec->authAsked.load()]);
    AuthNav(h, st, [=](bool second) {
      auto after2 = AuthLines();
      st->cached = second && after2.size() > k && after2[k] == "/auth auth=yes";
      g_c.Ok("auth-control-cached-credentials-sent-before-clear", st->cached, [NSString stringWithFormat:@"second navigation: first new server line '%s' (want auth=yes, from the auth cache)", after2.size() > k ? after2[k].c_str() : "(none)"]);
      st->seen = after2.size();
      cb(st);
    });
  });
}
void AuthAfter(H h, std::shared_ptr<AuthSt> st, std::function<void()> next) {
  AuthNav(h, st, [=](bool third) {
    auto lines = AuthLines();
    g_c.Ok("A-ClearHttpAuthCredentials-next-request-has-no-Authorization", third && lines.size() > st->seen && lines[st->seen] == "/auth auth=no", [NSString stringWithFormat:@"after ClearHttpAuthCredentials the first new server line is '%s' (want auth=no); lines since: %zu", lines.size() > st->seen ? lines[st->seen].c_str() : "(none)", lines.size() - st->seen]);
    if (auto t = AuthTab(h, st)) t->GetHost()->CloseBrowser(true);
    next();
  });
}
void CheckClear(H h) {
  NSString* tok = Token();
  auto cB = MakeCtx(Dir(@"Profile 1"));
  auto cA = CefRequestContext::GetGlobalContext();
  NSString* origin = Localhost(h->url());
  NSString* pageUrl = Localhost(Page(h, @"profile-clear.html"));
  auto wB = Open(cB, pageUrl);
  NSString* u1 = [Localhost(Page(h, @"index.html")) stringByAppendingFormat:@"?cache=%@a", tok];
  auto prime = [=](CefRefPtr<CefBrowser> tab, NSString* u, std::function<void(NSString*)> cb) {
    Ev(h, tab, [NSString stringWithFormat:@"window.noche.prime('%@')", u], true, cb);
  };
  auto hit = [=](CefRefPtr<CefBrowser> tab, NSString* u, std::function<void(NSString*)> cb) {
    Ev(h, tab, [NSString stringWithFormat:@"window.noche.hit('%@')", u], true, cb);
  };
  NavWait(h, h->first(), pageUrl, [=](bool aLoaded) {
  WaitFor(h, 20000, [=] { return Loaded(wB, wB->first()); }, [=](bool loaded0) {
    const bool loaded = loaded0 && aLoaded;
    Later(1.5, [=] {
      auto tabA = h->first();
      auto tabB = TabOf(wB->view, wB->first());
      g_c.Ok("windows-loaded", loaded, @"B fixture page loaded");
      SetCk(cA, origin, "clearA", [=](bool okA) { SetCk(cB, origin, "clearB", [=](bool okB) {
        g_c.Ok("cookies-set", okA && okB, @"clearA in A, clearB in B");
        prime(tabA, u1, [=](NSString* pa) { prime(tabB, u1, [=](NSString* pb) {
          g_c.Ok("cache-control-both-hit", [pa isEqualToString:@"0"] && [pb isEqualToString:@"0"], [NSString stringWithFormat:@"transferSize of the force-cache fetch before clearing: A %@, B %@ (0 = served by the HTTP cache)", pa, pb]);
          DelAllCk(cA, [=](int deleted) {
            g_c.Ok("A-DeleteCookies", deleted >= 1, [NSString stringWithFormat:@"DeleteCookies(\"\",\"\") in A deleted %d", deleted]);
            cA->ClearHttpCache(new CB([=] {
              PI(@"A ClearHttpCache completed");
              AuthPrime(h, [=](std::shared_ptr<AuthSt> st) {
              auto calls = std::make_shared<int>(0);
              cA->ClearHttpAuthCredentials(new CB([=] {
                ++*calls;
                AuthAfter(h, st, [=] {
                g_c.Ok("A-ClearHttpAuthCredentials-callback-once", *calls == 1, [NSString stringWithFormat:@"callback ran %d time(s) by the time the next navigation finished (want 1)", *calls]);
                ListCk(cA, [=](std::vector<std::string> a) { ListCk(cB, [=](std::vector<std::string> b) {
                  g_c.Ok("A-cookies-empty", !Has(a, "clearA"), [NSString stringWithFormat:@"A cookies: %@", Join(a)]);
                  g_c.Ok("B-keeps-its-cookie", Has(b, "clearB"), [NSString stringWithFormat:@"B cookies: %@", Join(b)]);
                  hit(tabA, u1, [=](NSString* ha) { hit(tabB, u1, [=](NSString* hb) {
                    g_c.Ok("A-cache-cleared", ha.intValue > 0, [NSString stringWithFormat:@"force-cache fetch in A after ClearHttpCache: transferSize %@ (>0 means a network fetch)", ha]);
                    g_c.Ok("B-cache-kept", [hb isEqualToString:@"0"], [NSString stringWithFormat:@"force-cache fetch in B: transferSize %@ (0 = still cached)", hb]);
                    ChromeWitness(h, tok, wB, cB, [=](bool formMade, bool pwSeeded) {
#ifndef NOCHE_CLEAR_API
                      PI(@"CefRequestContext::ClearBrowsingData is not in this engine build (NOCHE_CLEAR_API unset): the history, downloads, form data, time-range, storage and everything parts cannot be called; needs patch 0010");
                      g_c.Ok("clear-api", false, @"NOT RUN: CefRequestContext::ClearBrowsingData (engine patch 0010) missing; build with NOCHE_CLEAR_API=1 against the 0010 engine");
                      End(h, @"profile-clear");
#else
                      ClearChrome(h, tok, cB, formMade, pwSeeded, [=] { ClearRanges(h, tok, wB, cB, u1); });
#endif
                    });
                  }); });
                }); });
                });
              }));
              });
            }));
          });
        }); });
      }); });
    });
  });
  });
}
#ifdef NOCHE_CLEAR_API
// Time ranges (patch 0010). In A: localhost holds a cookie, a localStorage key and a cached URL written BEFORE t0; the origin
// 127.0.0.1 holds the same three AFTER t0. ClearBrowsingData(cookies|cache|site storage, since = t0) must remove only the after-t0 set,
// and leave B (written after t0 too) untouched. Then ClearBrowsingData(all, since = 0) on A removes the rest.
// Chrome-layer bits on B (patch 0010): downloads first (the download rows go, the visited-page rows stay), then history (its rows go, A's stay),
// then form data when the witness created some.
void ClearChrome(H h, NSString* tok, CefRefPtr<CefRequestContext> cB, bool formMade, bool pwSeeded, std::function<void()> next) {
  NSString* like = [@"histB=" stringByAppendingString:tok];
  NSString* likeA = [@"histA=" stringByAppendingString:tok];
  cB->ClearBrowsingData(CEF_BROWSING_DATA_DOWNLOADS, CefBaseTime(), new CB([=] {
    PollCount(h, 15000, [=] { return DownloadRowsIn(@"Profile 1", @"small.bin"); }, [](int n) { return n == 0; }, [=](bool dGone, int nD) {
      const int histB = HistoryRowsIn(@"Profile 1", like);
      g_c.Ok("downloads-clear-removes-B-download-rows", dGone && histB >= 1, [NSString stringWithFormat:@"after ClearBrowsingData(DOWNLOADS) on B: downloads_url_chains rows %d (want 0), B visited-page rows %d (want >= 1, untouched)", nD, histB]);
      cB->ClearBrowsingData(CEF_BROWSING_DATA_HISTORY, CefBaseTime(), new CB([=] {
        PollCount(h, 15000, [=] { return HistoryRowsIn(@"Profile 1", like); }, [](int n) { return n == 0; }, [=](bool hGone, int nH) {
          const int histA = HistoryRowsIn(@"Default", likeA);
          g_c.Ok("history-clear-removes-B-rows-and-keeps-A", hGone && histA >= 1, [NSString stringWithFormat:@"after ClearBrowsingData(HISTORY) on B: B urls rows %d (want 0), A urls rows %d (want >= 1)", nH, histA]);
          auto finish = [=] {
            if (!pwSeeded) { PI(@"PASSWORDS bit: not exercised, the seeded logins rows did not survive engine start (see password-witness); owner check"); next(); return; }
            cB->ClearBrowsingData(CEF_BROWSING_DATA_PASSWORDS, CefBaseTime(), new CB([=] {
              PollCount(h, 15000, [=] { return PwRows(@"Profile 1", @"nochetest-B"); }, [](int n) { return n == 0; }, [=](bool pGone, int nP) {
                const int pwA = PwRows(@"Default", @"nochetest-A");
                g_c.Ok("passwords-clear-removes-B-rows-and-keeps-A", pGone && pwA >= 1, [NSString stringWithFormat:@"after ClearBrowsingData(PASSWORDS) on B: B logins rows %d (want 0), A logins rows %d (want >= 1)", nP, pwA]);
                next();
              });
            }));
          };
          if (!formMade) { finish(); return; }
          cB->ClearBrowsingData(CEF_BROWSING_DATA_FORM_DATA, CefBaseTime(), new CB([=] {
            PollCount(h, 15000, [=] { return FormRowsIn(@"Profile 1", tok); }, [](int n) { return n == 0; }, [=](bool fGone, int nF) {
              g_c.Ok("form-data-clear-removes-B-autocomplete-rows", fGone, [NSString stringWithFormat:@"after ClearBrowsingData(FORM_DATA) on B: Web Data autocomplete rows %d (want 0)", nF]);
              finish();
            });
          }));
        });
      }));
    });
  }));
}

void ClearRanges(H h, NSString* tok, WP wB, CefRefPtr<CefRequestContext> cB, NSString* uB) {
  auto cA = CefRequestContext::GetGlobalContext();
  NSString* oldO = Localhost(h->url());
  NSString* newO = h->url();  // the 127.0.0.1 origin
  NSString* uOld = [Localhost(Page(h, @"index.html")) stringByAppendingFormat:@"?cache=%@old", tok];
  NSString* uNew = [Page(h, @"index.html") stringByAppendingFormat:@"?cache=%@new", tok];
  auto tabA = h->first();
  auto tabB = TabOf(wB->view, wB->first());
  const int kAll = CEF_BROWSING_DATA_COOKIES | CEF_BROWSING_DATA_CACHE | CEF_BROWSING_DATA_SITE_STORAGE;
  Ev(h, tabA, @"window.noche.ls('old', '1')", false, [=](NSString*) {
    Ev(h, tabA, [NSString stringWithFormat:@"window.noche.prime('%@')", uOld], true, [=](NSString*) {
      SetCk(cA, oldO, "oldCk", [=](bool) {
        // localStorage keeps an origin's last-modified time from its disk commit, which comes 5 s after the write (local_storage_impl.cc
        // kCommitDefaultDelaySecs); a shorter wait puts the commit after t0 and the clear then removes the before-t0 origin too.
        Later(7.0, [=] {
          const CefBaseTime t0 = CefBaseTime::Now();
          Later(0.3, [=] {
            // After t0: a second tab on the 127.0.0.1 origin in A, and B's data.
            auto t2 = h->view()->AddTab(Page(h, @"profile-clear.html").UTF8String, nullptr, CefBrowserSettings(), nullptr, false);
            Later(3.0, [=] {
              auto tab2 = TabOf(h->view(), t2 ? t2->GetIdentifier() : -1);
              Ev(h, tab2, @"window.noche.ls('new', '1')", false, [=](NSString*) {
                Ev(h, tab2, [NSString stringWithFormat:@"window.noche.prime('%@')", uNew], true, [=](NSString*) {
                  Ev(h, tabB, @"window.noche.ls('bkey', '1')", false, [=](NSString*) {
                    SetCk(cA, newO, "newCk", [=](bool) { SetCk(cB, oldO, "clearB", [=](bool) {
                      cA->ClearBrowsingData(kAll, t0, new CB([=] {
                        PI(@"A ClearBrowsingData(cookies|cache|site storage, since t0) completed");
                        ListCk(cA, [=](std::vector<std::string> a) { ListCk(cB, [=](std::vector<std::string> b) {
                          g_c.Ok("range-cookie-before-t0-kept", Has(a, "oldCk"), [NSString stringWithFormat:@"A cookies: %@", Join(a)]);
                          g_c.Ok("range-cookie-after-t0-removed", !Has(a, "newCk"), [NSString stringWithFormat:@"A cookies: %@", Join(a)]);
                          g_c.Ok("range-B-cookie-kept", Has(b, "clearB"), [NSString stringWithFormat:@"B cookies: %@", Join(b)]);
                          Ev(h, tabA, @"window.noche.ls('old')", false, [=](NSString* lo) {
                            Ev(h, tab2, @"window.noche.ls('new')", false, [=](NSString* ln) {
                              Ev(h, tabB, @"window.noche.ls('bkey')", false, [=](NSString* lb) {
                                g_c.Ok("range-storage", [lo isEqualToString:@"1"] && [ln isEqualToString:@"null"] && [lb isEqualToString:@"1"], [NSString stringWithFormat:@"localStorage: before-t0 origin '%@' (want 1), after-t0 origin '%@' (want null), B '%@' (want 1)", lo, ln, lb]);
                                Ev(h, tabA, [NSString stringWithFormat:@"window.noche.hit('%@')", uOld], true, [=](NSString* co) {
                                  Ev(h, tab2, [NSString stringWithFormat:@"window.noche.hit('%@')", uNew], true, [=](NSString* cn) {
                                    g_c.Ok("range-cache", [co isEqualToString:@"0"] && cn.intValue > 0, [NSString stringWithFormat:@"force-cache transferSize: before-t0 entry %@ (want 0), after-t0 entry %@ (want >0)", co, cn]);
                                    cA->ClearBrowsingData(kAll, CefBaseTime(), new CB([=] {
                                      ListCk(cA, [=](std::vector<std::string> a2) {
                                        Ev(h, tabA, @"window.noche.ls('old')", false, [=](NSString* lo2) {
                                          g_c.Ok("everything-clears-Default-data", !Has(a2, "oldCk") && [lo2 isEqualToString:@"null"], [NSString stringWithFormat:@"ClearBrowsingData(all, since 0) on Default: cookies %@, localStorage old '%@'", Join(a2), lo2]);
                                          ListCk(cB, [=](std::vector<std::string> b2) {
                                            g_c.Ok("everything-in-A-leaves-B", Has(b2, "clearB"), [NSString stringWithFormat:@"B cookies after Default was cleared: %@", Join(b2)]);
                                            Ev(h, tabB, @"window.noche.ls('bkey')", false, [=](NSString* lb2) {
                                              Ev(h, tabB, [NSString stringWithFormat:@"window.noche.hit('%@')", uB], true, [=](NSString* cb2) {
                                                g_c.Ok("everything-in-A-leaves-B-storage-and-cache", [lb2 isEqualToString:@"1"] && [cb2 isEqualToString:@"0"], [NSString stringWithFormat:@"after ClearBrowsingData(all, since 0) on Default: B localStorage 'bkey' '%@' (want 1), B force-cache transferSize for its primed URL %@ (want 0 = still cached)", lb2, cb2]);
                                                DelAllCk(cB, [=](int) { End(h, @"profile-clear"); });
                                              });
                                            });
                                              });
                                            });
                                          });
                                    }));
                                  });
                                });
                              });
                            });
                          });
                        }); });
                      }));
                    }); });
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
#endif

// ---- profile-delete (-2 after a relaunch) ----
void CheckDelete(H h) {
  NSString* p2 = Dir(@"Profile 2");
  auto c2 = std::make_shared<CefRefPtr<CefRequestContext>>(MakeCtx(p2));
  NSString* origin = Localhost(h->url());
  auto w2 = std::make_shared<WP>(Open(*c2, Localhost(Page(h, @"index.html?side=P2"))));
  WaitFor(h, 20000, [=] { return Loaded(*w2, (*w2)->first()); }, [=](bool loaded) {
    g_c.Ok("P2-window-loaded", loaded, @"Profile 2 window loaded");
    SetCk(*c2, origin, "nocheP2", [=](bool ok) {
      g_c.Ok("set-cookie-P2", ok, @"cookie in Profile 2");
      Flush(*c2, [=] {
        // Preferences is written about 10 s after the profile is created (profile-dirs measured 9.9 s), so wait for it.
        WaitFor(h, 25000, [=] { return Exists(Dir(@"Profile 2/Preferences")); }, [=](bool had) {
        g_c.Ok("P2-dir-and-preferences-exist", had, [NSString stringWithFormat:@"%@/Preferences exists=%d (waited up to 25 s)", p2, (int)had]);
        (*w2)->window->Close();
        WaitFor(h, 10000, [=] { return (*w2)->destroyed; }, [=](bool) {
          g_wins.clear(); *w2 = nullptr; *c2 = nullptr;  // every reference to Profile 2 is released
          Later(3.0, [=] {
            g_c.Ok("dir-survives-release", Exists(p2) && Exists(Dir(@"Default/Preferences")), [NSString stringWithFormat:@"after releasing every ref: Profile 2 exists=%d, Default/Preferences exists=%d (no in-session removal)", (int)Exists(p2), (int)Exists(Dir(@"Default/Preferences"))]);
            WriteMarker(@"delete", @"Profile 2\n");
            End(h, @"profile-delete (relaunch half: profile-delete-2)");
          });
        });
        });
      });
    });
  });
}
NSString* g_sweep = @"";
void CheckDelete2(H h) {
  g_c.Ok("phase-1-ran", g_sweep.length > 0, [NSString stringWithFormat:@"pre-engine sweep log: %@", g_sweep]);
  g_c.Ok("tombstoned-dir-swept", [g_sweep containsString:@"existed=1 removed=1"] && ![g_sweep containsString:@"kept"] && !Exists(Dir(@"Profile 2")), [NSString stringWithFormat:@"sweep log '%@', Profile 2 exists now=%d", g_sweep, (int)Exists(Dir(@"Profile 2"))]);
  g_c.Ok("Default-intact", Exists(Dir(@"Default/Preferences")) && Exists(Dir(@"Local State")), [NSString stringWithFormat:@"Default/Preferences=%d Local State=%d", (int)Exists(Dir(@"Default/Preferences")), (int)Exists(Dir(@"Local State"))]);
  // The deleted profile can come back as a fresh one if its name is reused, but the app never reuses a number: not asserted here.
  End(h, @"profile-delete-2");
}


// ---- profile-clear-callbacks (0010 callback contract: exactly once, also for an unknown mask and a destroyed context) ----
void CheckClearCallbacks(H h) {
#ifndef NOCHE_CLEAR_API
  PI(@"CefRequestContext::ClearBrowsingData is not in this engine build (NOCHE_CLEAR_API unset); needs patch 0010");
  g_c.Ok("clear-api", false, @"NOT RUN: CefRequestContext::ClearBrowsingData (engine patch 0010) missing; build with NOCHE_CLEAR_API=1 against the 0010 engine");
  End(h, @"profile-clear-callbacks");
#else
  auto ctxReady = [=](CefRefPtr<CefRequestContext> c, std::function<void(bool)> then) {
    auto inited = std::make_shared<bool>(false);
    c->GetCookieManager(new CB([inited] { *inited = true; }));
    WaitFor(h, 15000, [=] { return *inited; }, then);
  };
  auto cB = std::make_shared<CefRefPtr<CefRequestContext>>(MakeCtx(Dir(@"Profile 1")));
  ctxReady(*cB, [=](bool ok1) {
    g_c.Ok("context-initialized", ok1, @"Profile 1 context initialized");
    // (a) a mask with no known bit, and the empty mask: the callback runs once, and never from inside the call.
    const int kUnknown = (1 << 20) | (1 << 30);
    auto nUnknown = std::make_shared<int>(0), nZero = std::make_shared<int>(0);
    (*cB)->ClearBrowsingData(kUnknown, CefBaseTime(), new CB([=] { ++*nUnknown; }));
    (*cB)->ClearBrowsingData(0, CefBaseTime(), new CB([=] { ++*nZero; }));
    const int syncU = *nUnknown, syncZ = *nZero;
    Later(3.0, [=] {
      g_c.Ok("unknown-mask-callback-once", syncU == 0 && *nUnknown == 1, [NSString stringWithFormat:@"mask 0x%x: callbacks %d inside the call (want 0), %d after 3 s (want 1)", kUnknown, syncU, *nUnknown]);
      g_c.Ok("empty-mask-callback-once", syncZ == 0 && *nZero == 1, [NSString stringWithFormat:@"mask 0: callbacks %d inside the call (want 0), %d after 3 s (want 1)", syncZ, *nZero]);
      // (b) the context is destroyed right after the removal started: no crash, the callback runs at most once.
      auto cC = std::make_shared<CefRefPtr<CefRequestContext>>(MakeCtx(Dir(@"Profile 2")));
      ctxReady(*cC, [=](bool ok2) {
        g_c.Ok("context-2-initialized", ok2, @"Profile 2 context initialized");
        auto nDestroyed = std::make_shared<int>(0);
        const int kAll = CEF_BROWSING_DATA_COOKIES | CEF_BROWSING_DATA_CACHE | CEF_BROWSING_DATA_SITE_STORAGE | CEF_BROWSING_DATA_HISTORY | CEF_BROWSING_DATA_DOWNLOADS | CEF_BROWSING_DATA_FORM_DATA | CEF_BROWSING_DATA_PASSWORDS;
        (*cC)->ClearBrowsingData(kAll, CefBaseTime(), new CB([=] { ++*nDestroyed; }));
        *cC = nullptr;  // the last reference
        Later(3.0, [=] {
          g_c.Ok("destroyed-context-callback-at-most-once", *nDestroyed <= 1, [NSString stringWithFormat:@"callbacks after the context was released mid-removal and 3 s: %d (want <= 1; the engine is still running, so no crash)", *nDestroyed]);
          PI(@"destroyed-context callback ran %d time(s)", *nDestroyed);
          End(h, @"profile-clear-callbacks");
        });
      });
    });
  });
#endif
}

// ---- profile-upgrade ----
// A profile made by an older engine (run it against a copy, NOCHE_PROBE_ROOT) must start on this engine and load a page. The failure this
// guards is a startup abort (CefInitialize never returns), so reaching this code at all is most of the proof.
void CheckUpgrade(H h) {
  PI(@"profile root %@", Root());
  auto got = std::make_shared<std::string>();
  WaitFor(h, 20000, [=] { h->eval(h->first(), @"document.title", false, [=](NSString* r) { *got = r.UTF8String ?: ""; }); return got->find("probe") != std::string::npos; }, [=](bool ok) {
    g_c.Ok("page-loaded", ok, [NSString stringWithFormat:@"document.title of the first tab: '%s'", got->c_str()]);
    End(h, @"profile-upgrade");
  });
}

}  // namespace

void ProfilesPreEngine(NSString* check, NSString* root) {
  if (![check hasPrefix:@"profile-"]) return;
  NSFileManager* fm = NSFileManager.defaultManager;
  if (![check hasSuffix:@"-2"]) {
    for (NSString* n in @[ @"Profile 1", @"Profile 2" ]) [fm removeItemAtPath:[root stringByAppendingPathComponent:n] error:nil];
    if ([check isEqualToString:@"profile-clear"]) {
      // Seed one saved-password row per profile (no password can be saved hidden): Profile 1's Login Data is a copy of Default's (a prior launch wrote the schema),
      // both emptied and given one row with a blank password_value on the fixture host. The witness in ChromeWitness proves the rows survive engine start.
      NSString* src = [root stringByAppendingPathComponent:@"Default/Login Data"];
      NSString* p1 = [root stringByAppendingPathComponent:@"Profile 1"];
      [fm createDirectoryAtPath:p1 withIntermediateDirectories:YES attributes:nil error:nil];
      [fm copyItemAtPath:src toPath:[p1 stringByAppendingPathComponent:@"Login Data"] error:nil];
      for (NSArray* t in @[ @[ @"Default/Login Data", @"nochetest-A" ], @[ @"Profile 1/Login Data", @"nochetest-B" ] ]) {
        NSString* sql = [NSString stringWithFormat:@"delete from logins; insert into logins (origin_url, action_url, username_element, username_value, password_element, password_value, signon_realm, date_created, blacklisted_by_user, scheme) values ('http://localhost/', 'http://localhost/', 'u', '%@', 'p', x'', 'http://localhost/', 13300000000000000, 0, 0);", t[1]];
        std::string cmd = std::string("sqlite3 '") + [root stringByAppendingPathComponent:t[0]].UTF8String + "' \"" + sql.UTF8String + "\" 2>&1";
        if (FILE* f = popen(cmd.c_str(), "r")) { char b[256]; while (fgets(b, sizeof b, f)) fprintf(stderr, "[PROBE] seed %s", b); pclose(f); }
      }
    }
    return;
  }
  if (![check isEqualToString:@"profile-delete-2"]) return;
  // The app's launch sweep: delete the tombstoned directories named "Profile <n>" before CefInitialize; never anything else.
  NSString* marker = [root stringByAppendingPathComponent:@"profile-probe-delete.txt"];
  NSMutableString* log = [NSMutableString string];
  for (NSString* line in [[NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"]) {
    if (!line.length) continue;
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:@"^Profile [0-9]+$" options:0 error:nil];
    NSString* path = [root stringByAppendingPathComponent:line];
    if ([re numberOfMatchesInString:line options:0 range:NSMakeRange(0, line.length)] == 0) { [log appendFormat:@"kept '%@' (not a Profile <n> name); ", line]; continue; }
    const bool existed = [fm fileExistsAtPath:path];
    [fm removeItemAtPath:path error:nil];
    [log appendFormat:@"'%@' existed=%d removed=%d; ", line, (int)existed, (int)![fm fileExistsAtPath:path]];
  }
  g_sweep = [log copy];
}

bool RunProfilesCheck(NSString* check, const SurfHost& host) {
  static NSDictionary* table = @{ @"profile-dirs" : @0, @"profile-cookie" : @1, @"profile-cookie-2" : @2, @"profile-storage" : @3, @"profile-ext" : @4, @"profile-close" : @5,
                                  @"profile-incognito" : @6, @"profile-incognito-2" : @7, @"profile-clear" : @8, @"profile-delete" : @9, @"profile-delete-2" : @10, @"profile-upgrade" : @11, @"profile-clear-callbacks" : @12 };
  NSNumber* n = table[check];
  if (!n) return false;
  g_name = check;
  H h = std::make_shared<const SurfHost>(host);
  g_observe = host.observe;
  switch (n.intValue) {
    case 0: CheckDirs(h); break;
    case 1: CheckCookie(h); break;
    case 2: CheckCookie2(h); break;
    case 3: CheckStorage(h); break;
    case 4: CheckExt(h); break;
    case 5: CheckClose(h); break;
    case 6: CheckIncognito(h); break;
    case 7: CheckIncognito2(h); break;
    case 8: CheckClear(h); break;
    case 9: CheckDelete(h); break;
    case 11: CheckUpgrade(h); break;
    case 12: CheckClearCallbacks(h); break;
    default: CheckDelete2(h); break;
  }
  return true;
}
#endif
