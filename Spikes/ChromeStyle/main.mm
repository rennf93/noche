// Spike S1: Chrome-style browser views in a frameless CefWindow next to an AppKit sidebar.
// Throwaway code. Driven by a command file (--ctl <path>), results go to stderr as "[S1 <ms>] ...".
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "CefBridge.h"
#include <string>
#include <vector>
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/views/cef_fill_layout.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

static const int kSidebar = 197;
static int g_inset = 0;  // 6 when the card is on
static bool g_card = false;

static double NowMs() { return NSProcessInfo.processInfo.systemUptime * 1000.0; }
static void Log(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  fprintf(stderr, "[S1 %.1f] %s\n", NowMs(), s.UTF8String);
  fflush(stderr);
}

struct Tab {
  CefRefPtr<CefBrowserView> view;
  CefRefPtr<CefBrowser> browser;
  CefRefPtr<CefRegistration> reg;
  CefRefPtr<CefWindow> win;  // --windows mode only
  std::string title;
  bool alloy = false;
};
static std::vector<Tab> g_tabs;
static int g_cur = 0;
static CefRefPtr<CefWindow> g_window;
static NSWindow* g_nswin = nil;
static NSVisualEffectView* g_vev = nil;
static NSView* g_sidebar = nil;
static CefRefPtr<CefWindow> g_popwin;
static NSPopover* g_popover = nil;
static CefRefPtr<CefBrowserView> g_popview;
static CefRefPtr<CefBrowser> g_popbrowser;
static CefRefPtr<CefRegistration> g_popreg;
static int g_cdp_id = 1000;
static double g_switch_t0 = 0;

static std::string Trunc(const void* m, size_t n, size_t max = 900) {
  return std::string((const char*)m, std::min(n, max));
}

class Obs : public CefDevToolsMessageObserver {
 public:
  explicit Obs(int i) : idx_(i) {}
  bool OnDevToolsMessage(CefRefPtr<CefBrowser>, const void* m, size_t n) override {
    std::string s((const char*)m, n);
    if (s.rfind("{\"id\":", 0) == 0) Log(@"CDP tab=%d %s", idx_, Trunc(m, n).c_str());
    return false;
  }
 private:
  int idx_;
  IMPLEMENT_REFCOUNTING(Obs);
};

class TabClient : public CefClient, public CefLoadHandler, public CefDisplayHandler {
 public:
  explicit TabClient(int i) : idx_(i) {}
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> f, int status) override {
    if (f->IsMain()) Log(@"LOADEND tab=%d status=%d url=%s", idx_, status, f->GetURL().ToString().c_str());
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> f, ErrorCode c, const CefString& t,
                   const CefString& u) override {
    Log(@"LOADERROR tab=%d code=%d %s %s", idx_, (int)c, t.ToString().c_str(), u.ToString().c_str());
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    if (idx_ < (int)g_tabs.size()) g_tabs[idx_].title = title.ToString();
    Log(@"TITLE tab=%d %s", idx_, title.ToString().c_str());
  }
 private:
  int idx_;
  IMPLEMENT_REFCOUNTING(TabClient);
};

class BVDelegate : public CefBrowserViewDelegate {
 public:
  BVDelegate(int i, bool alloy) : idx_(i), alloy_(alloy) {}
  cef_runtime_style_t GetBrowserRuntimeStyle() override {
    return alloy_ ? CEF_RUNTIME_STYLE_ALLOY : CEF_RUNTIME_STYLE_CHROME;
  }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  void OnBrowserCreated(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> b) override {
    Log(@"BROWSER_CREATED tab=%d id=%d alloy=%d", idx_, b->GetIdentifier(), (int)alloy_);
    if (idx_ < (int)g_tabs.size()) {
      g_tabs[idx_].browser = b;
      g_tabs[idx_].reg = b->GetHost()->AddDevToolsMessageObserver(new Obs(idx_));
    }
  }
  void OnBrowserDestroyed(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> b) override {
    Log(@"BROWSER_DESTROYED tab=%d", idx_);
    if (idx_ < (int)g_tabs.size()) { g_tabs[idx_].reg = nullptr; g_tabs[idx_].browser = nullptr; }
  }
 private:
  int idx_;
  bool alloy_;
  IMPLEMENT_REFCOUNTING(BVDelegate);
};

static bool g_windows_mode = false;  // --windows: one frameless Chrome-style CefWindow per tab, child windows of an AppKit host
static NSWindow* g_host = nil;
static int g_open_windows = 0;
static bool g_sidebar_in_content = false;  // --sidebar-in-content: old behaviour, inside the Views content view
static NSView* HostView() { return (g_sidebar_in_content || g_windows_mode) ? g_nswin.contentView : g_nswin.contentView.superview; }
static void ApplyMask();
static int g_laid_inset = -1;
static CefRect TabRect() {
  NSRect f = g_host.frame;
  double H = NSScreen.screens[0].frame.size.height;
  double w = f.size.width - kSidebar - 2 * g_inset, h = f.size.height - 2 * g_inset;
  double x = f.origin.x + kSidebar + g_inset, yb = f.origin.y + g_inset;
  return CefRect((int)x, (int)(H - (yb + h)), (int)w, (int)h);
}

static void Layout() {
  if (g_windows_mode) {
    if (!g_host) return;
    for (size_t i = 0; i < g_tabs.size(); i++) if (g_tabs[i].win) g_tabs[i].win->SetBounds(TabRect());
    NSView* c = g_host.contentView;
    for (NSView* v in c.subviews) {
      if (v == g_sidebar) v.frame = NSMakeRect(0, 0, kSidebar, c.bounds.size.height);
      if (v == g_vev) v.frame = c.bounds;
    }
    return;
  }
  if (!g_window) return;
  // Views resets child bounds (fill layout), so the sidebar gap is a box layout inset instead.
  if (g_laid_inset != g_inset) {
    CefBoxLayoutSettings st;
    st.horizontal = true;
    st.inside_border_insets = CefInsets(g_inset, kSidebar + g_inset, g_inset, g_inset);
    st.cross_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH;
    CefRefPtr<CefBoxLayout> bl = g_window->SetToBoxLayout(st);
    for (auto& t : g_tabs) if (t.view) bl->SetFlexForView(t.view, 1);
    g_laid_inset = g_inset;
  }
  for (size_t i = 0; i < g_tabs.size(); i++) {
    if (g_tabs[i].view) g_tabs[i].view->SetVisible((int)i == g_cur);
  }
  g_window->Layout();
  if (g_nswin) {
    NSView* c = HostView();
    for (NSView* v in c.subviews) {
      if (v == g_sidebar) v.frame = NSMakeRect(0, 0, kSidebar, c.bounds.size.height);
      if (v == g_vev) v.frame = c.bounds;
    }
    ApplyMask();
  }
}

static void CardApply();

static void SwitchTo(int n) {
  if (n < 0 || n >= (int)g_tabs.size()) return;
  g_switch_t0 = NowMs();
  if (g_windows_mode) {
    int old = g_cur;
    g_cur = n;
    if (old != n && g_tabs[old].win) g_tabs[old].win->Hide();
    if (g_tabs[n].win) {
      g_tabs[n].win->SetBounds(TabRect());
      g_tabs[n].win->Show();
      NSWindow* nw = ((__bridge NSView*)g_tabs[n].win->GetWindowHandle()).window;
      [g_host addChildWindow:nw ordered:NSWindowAbove];
      [nw makeKeyAndOrderFront:nil];
    }
  } else {
    g_cur = n;
    Layout();
  }
  double t1 = NowMs();
  Log(@"SWITCH tab=%d setvisible_done_ms=%.2f", n, t1 - g_switch_t0);
  auto b = g_tabs[n].browser;
  if (b) {
    NSString* m = [NSString stringWithFormat:
        @"{\"id\":%d,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"new Promise(r=>requestAnimationFrame(()=>r('raf '+performance.now())))\",\"awaitPromise\":true,\"returnByValue\":true}}",
        ++g_cdp_id];
    double t0 = g_switch_t0;
    b->GetHost()->SendDevToolsMessage(m.UTF8String, strlen(m.UTF8String));
    Log(@"SWITCH_RAF_REQUESTED tab=%d t0=%.1f", n, t0);
  }
}

static void Cdp(int tab, NSString* method, NSString* params) {
  if (tab < 0 || tab >= (int)g_tabs.size() || !g_tabs[tab].browser) { Log(@"CDP no browser for tab %d", tab); return; }
  NSString* m = [NSString stringWithFormat:@"{\"id\":%d,\"method\":\"%@\",\"params\":%@}", ++g_cdp_id, method, params ?: @"{}"];
  g_tabs[tab].browser->GetHost()->SendDevToolsMessage(m.UTF8String, strlen(m.UTF8String));
  Log(@"CDP_SENT tab=%d id=%d %@", tab, g_cdp_id, method);
}

static NSString* JsonStr(NSString* s) {
  NSData* d = [NSJSONSerialization dataWithJSONObject:@[ s ] options:0 error:nil];
  NSString* a = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  return [a substringWithRange:NSMakeRange(1, a.length - 2)];
}

static void Js(int tab, NSString* code) {
  Cdp(tab, @"Runtime.evaluate",
      [NSString stringWithFormat:@"{\"expression\":%@,\"awaitPromise\":true,\"returnByValue\":true}", JsonStr(code)]);
}

static NSView* FindByClass(NSView* v, NSString* cls) {
  if ([NSStringFromClass(v.class) isEqualToString:cls]) return v;
  for (NSView* s in v.subviews) { NSView* r = FindByClass(s, cls); if (r) return r; }
  return nil;
}
// For Views-hosted browsers GetWindowHandle() is the window's BridgedContentView; the page itself is WebContentsViewCocoa.
static NSView* WebNSView(CefRefPtr<CefBrowser> b) {
  NSView* h = (__bridge NSView*)b->GetHost()->GetWindowHandle();
  return FindByClass(h, @"WebContentsViewCocoa") ?: h;
}
static void ApplyMask() {
  // Views draws page pixels through the window compositor layer, not through the web view's own layer,
  // so the rounded clip is a mask on ViewsCompositorSuperview covering the card rect.
  if (!g_nswin || g_windows_mode) return;
  NSView* csv = FindByClass(HostView(), @"ViewsCompositorSuperview");
  if (!csv) { Log(@"MASK no compositor view"); return; }
  NSSize sz = g_nswin.frame.size;  // frame is already the new size when CEF reports bounds; contentView.bounds can lag a step
  NSRect r = NSMakeRect(kSidebar + g_inset, g_inset, sz.width - kSidebar - 2 * g_inset, sz.height - 2 * g_inset);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  csv.wantsLayer = YES;
  if (g_card) {
    CAShapeLayer* m = [CAShapeLayer layer];
    CGPathRef path = CGPathCreateWithRoundedRect(NSRectToCGRect(r), 10, 10, NULL);
    m.path = path;
    CGPathRelease(path);
    csv.layer.mask = m;
  } else {
    csv.layer.mask = nil;
  }
  [CATransaction commit];
}

static NSView* BrowserNSView(int tab) {
  if (tab < 0 || tab >= (int)g_tabs.size() || !g_tabs[tab].browser) return nil;
  return WebNSView(g_tabs[tab].browser);
}

static void CardApply() {
  NSView* v = BrowserNSView(g_cur);
  if (!v) { Log(@"CARD no view"); return; }
  v.wantsLayer = YES;
  v.layer.cornerRadius = 10;
  v.layer.masksToBounds = YES;
  Log(@"CARD applied view=%@ frame=%@ layer=%@", NSStringFromClass(v.class), NSStringFromRect(v.frame), v.layer);
}

static void CardSet(bool on) {
  g_card = on;
  g_inset = on ? 6 : 0;
  if (on) {
    if (!g_vev) {
      g_vev = [[NSVisualEffectView alloc] initWithFrame:HostView().bounds];
      g_vev.material = NSVisualEffectMaterialSidebar;
      g_vev.blendingMode = NSVisualEffectBlendingModeBehindWindow;
      g_vev.state = NSVisualEffectStateActive;
      g_vev.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      g_nswin.opaque = NO;
      g_nswin.backgroundColor = [NSColor clearColor];
      [HostView() addSubview:g_vev positioned:NSWindowBelow relativeTo:nil];
    }
    g_window->SetBackgroundColor(0);
  } else {
    NSView* v = BrowserNSView(g_cur);
    if (v) { v.layer.cornerRadius = 0; v.layer.masksToBounds = NO; }
    [g_vev removeFromSuperview];
    g_vev = nil;
  }
  Layout();
}

@interface S1Sidebar : NSView
@end
@implementation S1Sidebar
- (void)nextTab:(id)sender {
  double t = NowMs();
  Log(@"SIDEBAR click next (button action) t=%.1f", t);
  SwitchTo((g_cur + 1) % (int)g_tabs.size());
}
- (void)ping:(id)sender { Log(@"SIDEBAR click ping"); }
- (void)popup:(id)sender { Log(@"SIDEBAR click popup"); [NSNotificationCenter.defaultCenter postNotificationName:@"S1Popup" object:sender]; }
@end

static NSButton* g_popBtn = nil;

static void MakeSidebar() {
  NSView* c = HostView();
  S1Sidebar* sb = [[S1Sidebar alloc] initWithFrame:NSMakeRect(0, 0, kSidebar, c.bounds.size.height)];
  g_sidebar = sb;
  g_sidebar.wantsLayer = YES;
  g_sidebar.layer.backgroundColor = [NSColor colorWithSRGBRed:0.2 green:0.3 blue:0.7 alpha:1].CGColor;
  g_sidebar.autoresizingMask = NSViewHeightSizable;
  auto btn = ^NSButton*(NSString* t, SEL s, CGFloat y) {
    NSButton* b = [NSButton buttonWithTitle:t target:g_sidebar action:s];
    b.frame = NSMakeRect(20, y, 150, 30);
    b.autoresizingMask = NSViewMinYMargin;
    [g_sidebar addSubview:b];
    return b;
  };
  CGFloat top = c.bounds.size.height;
  btn(@"Next tab", @selector(nextTab:), top - 50);
  btn(@"Ping", @selector(ping:), top - 90);
  g_popBtn = btn(@"Ext popup", @selector(popup:), top - 130);
  [c addSubview:g_sidebar positioned:NSWindowAbove relativeTo:nil];
  Log(@"SIDEBAR added, contentView=%@ subviews=%lu", NSStringFromClass(c.class), (unsigned long)c.subviews.count);
}

static NSPoint WinPt(double x, double yTop) {
  return NSMakePoint(x, HostView().bounds.size.height - yTop);
}

static void NSMouse(double x, double yTop) {
  NSPoint p = WinPt(x, yTop);
  NSView* hit = [g_nswin.contentView.superview hitTest:p];
  for (NSView* v = hit; v; v = v.superview) { Log(@"  hit chain %@", NSStringFromClass(v.class)); }
  Log(@"NSCLICK hitTest -> %@ (superview-of-content hit), content hit -> %@", NSStringFromClass(hit.class),
      NSStringFromClass([g_nswin.contentView hitTest:p].class));
  for (NSNumber* t in @[ @(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp) ]) {
    NSEvent* e = [NSEvent mouseEventWithType:(NSEventType)t.integerValue location:p modifierFlags:0
                                   timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:g_nswin.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
    [NSApp postEvent:e atStart:NO];
  }
  Log(@"NSCLICK at (%.0f,%.0f) top-left", x, yTop);
}

static void NSType(NSString* text) {
  for (NSUInteger i = 0; i < text.length; i++) {
    NSString* ch = [text substringWithRange:NSMakeRange(i, 1)];
    for (NSNumber* t in @[ @(NSEventTypeKeyDown), @(NSEventTypeKeyUp) ]) {
      NSEvent* e = [NSEvent keyEventWithType:(NSEventType)t.integerValue location:NSZeroPoint modifierFlags:0
                                   timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:g_nswin.windowNumber context:nil characters:ch
                 charactersIgnoringModifiers:ch isARepeat:NO keyCode:0];
      [g_nswin sendEvent:e];
    }
  }
  Log(@"NSTYPE %@ (firstResponder=%@)", text, NSStringFromClass(g_nswin.firstResponder.class));
}

static void DumpTree(NSView* v, int depth) {
  Log(@"VIEW %*s%@ frame=%@ hidden=%d", depth * 2, "", NSStringFromClass(v.class), NSStringFromRect(v.frame), (int)v.hidden);
  for (NSView* s in v.subviews) DumpTree(s, depth + 1);
}

static NSString* g_ctl = nil;
static void PopupHook(int tab, NSString* mode, NSString* url);

static void RunCommand(NSString* line) {
  NSArray* a = [line componentsSeparatedByString:@" "];
  NSString* c = a[0];
  NSString* rest = a.count > 1 ? [[a subarrayWithRange:NSMakeRange(1, a.count - 1)] componentsJoinedByString:@" "] : @"";
  Log(@"CMD %@", line);
  if ([c isEqualToString:@"tab"]) SwitchTo(rest.intValue);
  else if ([c isEqualToString:@"next"]) SwitchTo((g_cur + 1) % (int)g_tabs.size());
  else if ([c isEqualToString:@"load"]) {
    int t = [a[1] intValue];
    NSString* u = [[a subarrayWithRange:NSMakeRange(2, a.count - 2)] componentsJoinedByString:@" "];
    if (t < (int)g_tabs.size() && g_tabs[t].browser) g_tabs[t].browser->GetMainFrame()->LoadURL(u.UTF8String);
  } else if ([c isEqualToString:@"reload"]) {
    int t = rest.intValue;
    if (g_tabs[t].browser) g_tabs[t].browser->ReloadIgnoreCache();
  } else if ([c isEqualToString:@"js"]) {
    Js([a[1] intValue], [[a subarrayWithRange:NSMakeRange(2, a.count - 2)] componentsJoinedByString:@" "]);
  } else if ([c isEqualToString:@"cdp"]) {
    Cdp([a[1] intValue], a[2], [[a subarrayWithRange:NSMakeRange(3, a.count - 3)] componentsJoinedByString:@" "]);
  } else if ([c isEqualToString:@"click"]) {
    int t = [a[1] intValue];
    NSString* xy = [NSString stringWithFormat:@"\"x\":%@,\"y\":%@,\"button\":\"left\",\"clickCount\":1", a[2], a[3]];
    Cdp(t, @"Input.dispatchMouseEvent", [NSString stringWithFormat:@"{\"type\":\"mouseMoved\",\"x\":%@,\"y\":%@}", a[2], a[3]]);
    Cdp(t, @"Input.dispatchMouseEvent", [NSString stringWithFormat:@"{\"type\":\"mousePressed\",%@}", xy]);
    Cdp(t, @"Input.dispatchMouseEvent", [NSString stringWithFormat:@"{\"type\":\"mouseReleased\",%@}", xy]);
  } else if ([c isEqualToString:@"nsclick"]) NSMouse([a[1] doubleValue], [a[2] doubleValue]);
  else if ([c isEqualToString:@"nstype"]) NSType(rest);
  else if ([c isEqualToString:@"frontmost"]) { [NSApp activateIgnoringOtherApps:YES]; [g_nswin makeKeyAndOrderFront:nil]; }
  else if ([c isEqualToString:@"setframe"]) {
    NSRect f = g_nswin.frame;
    f.size = NSMakeSize([a[1] doubleValue], [a[2] doubleValue]);
    [g_nswin setFrame:f display:YES animate:(a.count > 3)];
    Log(@"FRAME %@", NSStringFromRect(g_nswin.frame));
  } else if ([c isEqualToString:@"resizeloop"]) {
    // Steps the frame width/height from the current size to w,h and back over ms, like a drag, with display:YES each step.
    double w1 = [a[1] doubleValue], h1 = [a[2] doubleValue], ms = [a[3] doubleValue];
    NSRect f0 = g_nswin.frame;
    int steps = (int)(ms / 16.0);
    __block int i = 0;
    Log(@"RESIZELOOP start %@ -> %gx%g steps=%d", NSStringFromRect(f0), w1, h1, steps);
    [NSTimer scheduledTimerWithTimeInterval:0.016 repeats:YES block:^(NSTimer* t) {
      double k = (double)i / steps; double u = k < 0.5 ? k * 2 : (1 - k) * 2;
      NSRect f = f0;
      f.size.width = f0.size.width + (w1 - f0.size.width) * u;
      f.size.height = f0.size.height + (h1 - f0.size.height) * u;
      f.origin.y = f0.origin.y + f0.size.height - f.size.height;
      [g_nswin setFrame:f display:YES];
      if (++i > steps) { [t invalidate]; Log(@"RESIZELOOP end %@", NSStringFromRect(g_nswin.frame)); }
    }];
  } else if ([c isEqualToString:@"info"]) {
    Log(@"INFO windowNumber=%ld frame=%@ cur=%d tabs=%lu pid=%d", (long)g_nswin.windowNumber,
        NSStringFromRect(g_nswin.frame), g_cur, (unsigned long)g_tabs.size(), getpid());
    for (size_t i = 0; i < g_tabs.size(); i++) if (g_tabs[i].view) {
      CefRect vb = g_tabs[i].view->GetBounds();
      Log(@"INFO tab=%zu views bounds=%d,%d %dx%d visible=%d", i, vb.x, vb.y, vb.width, vb.height, (int)g_tabs[i].view->IsVisible());
    }
    CefRect wb = g_window->GetBounds();
    Log(@"INFO window bounds=%d,%d %dx%d clientarea=%d,%d %dx%d", wb.x, wb.y, wb.width, wb.height, g_window->GetClientAreaBoundsInScreen().x, g_window->GetClientAreaBoundsInScreen().y, g_window->GetClientAreaBoundsInScreen().width, g_window->GetClientAreaBoundsInScreen().height);
    DumpTree(g_nswin.contentView.superview, 0);
  } else if ([c isEqualToString:@"windows"]) {
    for (NSWindow* w in NSApp.windows)
      Log(@"WINDOW %ld %@ frame=%@ visible=%d key=%d level=%ld parent=%ld sheet=%d title=%@", (long)w.windowNumber,
          NSStringFromClass(w.class), NSStringFromRect(w.frame), (int)w.visible, (int)w.keyWindow, (long)w.level,
          (long)w.parentWindow.windowNumber, (int)w.isSheet, w.title);
  } else if ([c isEqualToString:@"winclick"]) {
    // winclick <windowNumber> x y : x,y in that window's top-left coords
    NSWindow* w = [NSApp windowWithWindowNumber:[a[1] integerValue]];
    NSPoint p = NSMakePoint([a[2] doubleValue], w.contentView.bounds.size.height - [a[3] doubleValue]);
    for (NSNumber* t in @[ @(NSEventTypeLeftMouseDown), @(NSEventTypeLeftMouseUp) ]) {
      NSEvent* e = [NSEvent mouseEventWithType:(NSEventType)t.integerValue location:p modifierFlags:0
                                     timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber
                                       context:nil eventNumber:0 clickCount:1 pressure:1];
      [NSApp postEvent:e atStart:NO];
    }
    Log(@"WINCLICK win=%@ at (%@,%@)", a[1], a[2], a[3]);
  } else if ([c isEqualToString:@"popjs"]) {
    NSString* code = rest;
    NSString* m = [NSString stringWithFormat:@"{\"id\":%d,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":%@,\"awaitPromise\":true,\"returnByValue\":true}}", ++g_cdp_id, JsonStr(code)];
    if (g_popbrowser) g_popbrowser->GetHost()->SendDevToolsMessage(m.UTF8String, strlen(m.UTF8String));
    else Log(@"popjs: no popup browser");
  } else if ([c isEqualToString:@"layer"]) {
    // layer <ViewClassName> <radius>: round that view's layer and clip; prints the layer tree below it
    NSView* v = FindByClass(HostView(), a[1]);
    if (!v) { Log(@"LAYER no view %@", a[1]); }
    else {
      v.wantsLayer = YES;
      if (a.count > 2) { v.layer.cornerRadius = [a[2] doubleValue]; v.layer.masksToBounds = YES; }
      Log(@"LAYER %@ layer=%@ radius=%g masks=%d sublayers=%@", a[1], NSStringFromClass(v.layer.class),
          v.layer.cornerRadius, (int)v.layer.masksToBounds, v.layer.sublayers);
    }
  } else if ([c isEqualToString:@"maskcard"]) { ApplyMask();
  } else if ([c isEqualToString:@"closewin"]) {
    NSWindow* w = [NSApp windowWithWindowNumber:[a[1] integerValue]];
    Log(@"CLOSEWIN %@ %@", a[1], NSStringFromClass(w.class));
    [w orderOut:nil];
  } else if ([c isEqualToString:@"card"]) CardSet([rest isEqualToString:@"on"]);
  else if ([c isEqualToString:@"popup"]) PopupHook(0, a[1], a.count > 2 ? a[2] : @"");
  else if ([c isEqualToString:@"quit"]) {
    if (g_windows_mode) { for (auto& t : g_tabs) if (t.win) t.win->Close(); }
    else g_window->Close();
  }
  else Log(@"CMD unknown");
}

static void PollCtl() {
  NSString* s = [NSString stringWithContentsOfFile:g_ctl encoding:NSUTF8StringEncoding error:nil];
  if (s.length == 0) return;
  [@"" writeToFile:g_ctl atomically:NO encoding:NSUTF8StringEncoding error:nil];
  for (NSString* l in [s componentsSeparatedByString:@"\n"]) {
    if (l.length) RunCommand(l);
  }
}

// ---- C5 popup experiments -------------------------------------------------------------------

class PopBVDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  void OnBrowserCreated(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> b) override {
    g_popbrowser = b;
    g_popreg = b->GetHost()->AddDevToolsMessageObserver(new Obs(99));
    Log(@"POP BROWSER_CREATED id=%d", b->GetIdentifier());
  }
 private:
  IMPLEMENT_REFCOUNTING(PopBVDelegate);
};

class PopWinDelegate : public CefWindowDelegate {
 public:
  void OnWindowCreated(CefRefPtr<CefWindow> w) override {
    w->AddChildView(g_popview);
    w->SetToFillLayout();
    w->Show();
  }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(0, 0, 360, 520); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { g_popwin = nullptr; Log(@"POP window destroyed"); }
 private:
  IMPLEMENT_REFCOUNTING(PopWinDelegate);
};

static void PopupHook(int, NSString* mode, NSString* url) {
  if ([mode isEqualToString:@"win"] || [mode isEqualToString:@"popover"]) {
    g_popview = CefBrowserView::CreateBrowserView(new TabClient(90), url.UTF8String, CefBrowserSettings(), nullptr,
                                                  nullptr, new PopBVDelegate());
    Log(@"POP CreateBrowserView -> %p", g_popview.get());
    g_popwin = CefWindow::CreateTopLevelWindow(new PopWinDelegate());
    g_popwin->Show();
    if ([mode isEqualToString:@"win"]) {
      // Child window just right of the sidebar button, like a popover would sit.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSView* pv = (__bridge NSView*)g_popwin->GetWindowHandle();
        NSWindow* pw = pv.window;
        NSRect bf = [g_nswin convertRectToScreen:[g_sidebar convertRect:g_popBtn.frame toView:nil]];
        [pw setFrameOrigin:NSMakePoint(NSMaxX(bf) + 8, NSMaxY(bf) - pw.frame.size.height)];
        [g_nswin addChildWindow:pw ordered:NSWindowAbove];
        Log(@"POP child window placed frame=%@ windowNumber=%ld", NSStringFromRect(pw.frame), (long)pw.windowNumber);
      });
    } else {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSView* bv = g_popbrowser ? WebNSView(g_popbrowser) : nil;
        Log(@"POP popover: browser NSView=%@ superview=%@", bv, bv.superview);
        NSViewController* vc = [NSViewController new];
        vc.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 520)];
        g_popover = [NSPopover new];
        g_popover.contentViewController = vc;
        g_popover.behavior = NSPopoverBehaviorApplicationDefined;
        [g_popover showRelativeToRect:g_popBtn.bounds ofView:g_popBtn preferredEdge:NSRectEdgeMaxX];
        if (bv) {
          bv.frame = vc.view.bounds;
          [vc.view addSubview:bv];
          Log(@"POP popover: reparented, new superview=%@ window=%@", bv.superview, bv.window);
        }
      });
    }
  } else if ([mode isEqualToString:@"close"]) {
    [g_popover close];
    if (g_popwin) g_popwin->Close();
  }
}

static void PopupNotif() { PopupHook(0, @"win", @"chrome://version"); }

// ---- window and app -------------------------------------------------------------------------
class TabWinDelegate : public CefWindowDelegate {
 public:
  explicit TabWinDelegate(int i) : idx_(i) {}
  void OnWindowCreated(CefRefPtr<CefWindow> w) override {
    g_tabs[idx_].win = w;
    w->AddChildView(g_tabs[idx_].view);
    w->SetToFillLayout();
    if (idx_ == g_cur) {
      w->Show();
      NSWindow* nw = ((__bridge NSView*)w->GetWindowHandle()).window;
      [g_host addChildWindow:nw ordered:NSWindowAbove];
    }
    Log(@"TABWIN created tab=%d shown=%d", idx_, (int)(idx_ == g_cur));
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    if (idx_ < (int)g_tabs.size()) g_tabs[idx_].win = nullptr;
    if (--g_open_windows == 0) {
      Log(@"all tab windows destroyed, shutting down");
      g_tabs.clear();
      dispatch_async(dispatch_get_main_queue(), ^{ [NCEngine shutdown]; exit(0); });
    }
  }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return TabRect(); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
 private:
  int idx_;
  IMPLEMENT_REFCOUNTING(TabWinDelegate);
};

@interface S1Host : NSWindow
@end
@implementation S1Host
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

class WinDelegate : public CefWindowDelegate {
 public:
  void OnWindowCreated(CefRefPtr<CefWindow> w) override {
    g_window = w;
    for (auto& t : g_tabs) w->AddChildView(t.view);
    w->Show();
    g_nswin = ((__bridge NSView*)w->GetWindowHandle()).window;
    Log(@"WINDOW created nswindow=%@ content=%@", NSStringFromClass(g_nswin.class), NSStringFromClass(g_nswin.contentView.class));
    MakeSidebar();
    Layout();
    w->Activate();
  }
  void OnWindowBoundsChanged(CefRefPtr<CefWindow>, const CefRect&) override { Layout(); }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(120, 120, 1280, 800); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    Log(@"WINDOW destroyed, shutting down");
    g_tabs.clear();
    g_window = nullptr;
    dispatch_async(dispatch_get_main_queue(), ^{ [NCEngine shutdown]; exit(0); });
  }
 private:
  IMPLEMENT_REFCOUNTING(WinDelegate);
};

@interface S1Delegate : NSObject <NSApplicationDelegate>
@end
@implementation S1Delegate
- (void)tryToTerminateApplication:(id)sender {
  if (g_windows_mode) { for (auto& t : g_tabs) if (t.win) t.win->Close(); }
  else if (g_window) g_window->Close();
}
- (void)applicationDidFinishLaunching:(NSNotification*)n {
  NSArray<NSString*>* args = NSProcessInfo.processInfo.arguments;
  int ntabs = 1, port = 0;
  bool hybrid = false;
  NSString* first = @"about:blank";
  for (NSUInteger i = 1; i < args.count; i++) {
    if ([args[i] isEqualToString:@"--tabs"]) ntabs = args[++i].intValue;
    else if ([args[i] isEqualToString:@"--port"]) port = args[++i].intValue;
    else if ([args[i] isEqualToString:@"--ctl"]) g_ctl = args[++i];
    else if ([args[i] isEqualToString:@"--url"]) first = args[++i];
    else if ([args[i] isEqualToString:@"--hybrid"]) hybrid = true;
    else if ([args[i] isEqualToString:@"--sidebar-in-content"]) g_sidebar_in_content = true;
    else if ([args[i] isEqualToString:@"--windows"]) g_windows_mode = true;
    else if ([args[i] isEqualToString:@"--cache"]) {}
  }
  NSString* cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Spikes/s1"];
  for (NSUInteger i = 1; i + 1 < args.count; i++) if ([args[i] isEqualToString:@"--cache"]) cache = args[i + 1];
  [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
  NSError* err = nil;
  if (![NCEngine startWithCachePath:cache error:&err]) { Log(@"ENGINE FAIL %@", err); exit(4); }
  Log(@"ENGINE up, cache=%@ tabs=%d", cache, ntabs);

  for (int i = 0; i < ntabs; i++) {
    NSString* url = first;
    if (port && ntabs > 1) url = [NSString stringWithFormat:@"http://127.0.0.1:%d/many/%02d.html", port, i + 1];
    bool alloy = hybrid && i > 0;
    g_tabs.emplace_back();
    g_tabs.back().alloy = alloy;
    g_tabs.back().view = CefBrowserView::CreateBrowserView(new TabClient(i), url.UTF8String, CefBrowserSettings(),
                                                           nullptr, nullptr, new BVDelegate(i, alloy));
    Log(@"CreateBrowserView tab=%d alloy=%d -> %p", i, (int)alloy, g_tabs.back().view.get());
  }
  if (g_windows_mode) {
    g_host = [[S1Host alloc] initWithContentRect:NSMakeRect(240, 520, 1280, 800)
                                        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable
                                          backing:NSBackingStoreBuffered defer:NO];
    g_host.releasedWhenClosed = NO;
    g_host.backgroundColor = [NSColor colorWithSRGBRed:0.1 green:0.1 blue:0.1 alpha:1];
    g_nswin = g_host;
    MakeSidebar();
    [g_host makeKeyAndOrderFront:nil];
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification object:g_host queue:nil
                                                usingBlock:^(NSNotification*) { Layout(); }];
    for (int i = 0; i < ntabs; i++) { g_open_windows++; CefWindow::CreateTopLevelWindow(new TabWinDelegate(i)); }
  } else {
    g_window = CefWindow::CreateTopLevelWindow(new WinDelegate());
  }
  [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification object:nil queue:nil
                                              usingBlock:^(NSNotification* n) { if (n.object == g_nswin && !g_windows_mode) ApplyMask(); }];
  [NSNotificationCenter.defaultCenter addObserverForName:@"S1Popup" object:nil queue:nil usingBlock:^(NSNotification*) { PopupNotif(); }];
  if (g_ctl) {
    [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer*) { PollCtl(); }];
  }
}
@end

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    NCApplication* app = (NCApplication*)NCApplication.sharedApplication;
    static S1Delegate* d = [S1Delegate new];
    app.delegate = d;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app run];
  }
  return 0;
}
