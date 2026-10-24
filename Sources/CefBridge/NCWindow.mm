#import "CefBridge.h"
#import "NCTabInternal.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#include <map>
#include <set>
#include "include/cef_client.h"
#include "include/cef_command_handler.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

@interface NCWindow ()
- (CefRect)cefInitialBounds;
- (void)applyMask;
- (void)devToolsGone:(CefRefPtr<CefBrowser>)browser;
- (void)devToolsAbout:(CefRefPtr<CefBrowser>)browser;
- (void)closeWindowNow;
- (void)closeWindowWhenDevToolsGone:(int)left;
- (void)cefWindowCreated:(CefRefPtr<CefWindow>)window;
- (void)cefWindowDestroyed;
- (void)browserCreated:(CefRefPtr<CefBrowserView>)view browser:(CefRefPtr<CefBrowser>)browser;
- (void)tabAdded:(CefRefPtr<CefBrowser>)browser active:(BOOL)active;
- (void)activeTabChangedFrom:(CefRefPtr<CefBrowser>)previous to:(CefRefPtr<CefBrowser>)active;
- (void)browserClosing:(CefRefPtr<CefBrowser>)browser;
- (void)browser:(CefRefPtr<CefBrowser>)browser update:(void (^)(NCTab*))mutate;
- (void)browser:(CefRefPtr<CefBrowser>)browser finishedLoadWithStatus:(int)status;
- (void)browser:(CefRefPtr<CefBrowser>)browser failedLoadWithCode:(int)code url:(NSString*)url;
- (void)browser:(CefRefPtr<CefBrowser>)browser faviconURLs:(const std::vector<CefString>&)urls;
- (BOOL)chromeCommand:(int)commandId;
@end

namespace {

NSInteger g_devtools_created = 0, g_devtools_closed = 0;
// DevTools has its own client, so its load end never reaches ours: loaded is read off the browser (polled by the checks).
std::map<int, CefRefPtr<CefBrowser>> g_devtools_browsers;
std::set<int> g_devtools_loaded_ids;

// New tabs start on the card fill (live-ui.md section 2) so a tab never flashes white.
CefBrowserSettings TabSettings() {
  CefBrowserSettings s;
  s.background_color = 0xFF1F1F1F;
  return s;
}

// One client per window: Chrome-created tabs reuse the first tab's client (cef_browser_view.h AddTab), so every
// callback dispatches by browser identifier inside NCWindow.
class NCClient : public CefClient,
                 public CefLifeSpanHandler,
                 public CefLoadHandler,
                 public CefDisplayHandler,
                 public CefCommandHandler {
 public:
  explicit NCClient(NCWindow* w) : w_(w) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }

  // Called for every DevTools popup of a tab of this window, whoever asked for it (menu, accelerator, context menu).
  void OnBeforeDevToolsPopup(CefRefPtr<CefBrowser> b, CefWindowInfo&, CefRefPtr<CefClient>&, CefBrowserSettings&,
                             CefRefPtr<CefDictionaryValue>&, bool*) override {
    NC_CEF_CALLBACK;
    [w_ devToolsAbout:b];
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> b) override { NC_CEF_CALLBACK; [w_ browserClosing:b]; }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> b, bool loading, bool back, bool forward) override {
    NC_CEF_CALLBACK;
    [w_ browser:b update:^(NCTab* t) {
      t.isLoading = loading;
      t.canGoBack = back;
      t.canGoForward = forward;
    }];
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, int status) override {
    NC_CEF_CALLBACK;
    if (f->IsMain()) [w_ browser:b finishedLoadWithStatus:status];
  }
  void OnLoadError(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, ErrorCode code, const CefString&,
                   const CefString& failedUrl) override {
    NC_CEF_CALLBACK;
    if (f->IsMain() && code != ERR_ABORTED) [w_ browser:b failedLoadWithCode:(int)code url:@(failedUrl.ToString().c_str())];
  }
  void OnTitleChange(CefRefPtr<CefBrowser> b, const CefString& title) override {
    NC_CEF_CALLBACK;
    NSString* s = @(title.ToString().c_str());
    [w_ browser:b update:^(NCTab* t) { t.title = s; }];
  }
  void OnAddressChange(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, const CefString& url) override {
    NC_CEF_CALLBACK;
    if (!f->IsMain()) return;
    NSString* s = @(url.ToString().c_str());
    [w_ browser:b update:^(NCTab* t) { t.url = s; }];
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser> b, const std::vector<CefString>& urls) override {
    NC_CEF_CALLBACK;
    [w_ browser:b faviconURLs:urls];
  }
  bool OnChromeCommand(CefRefPtr<CefBrowser>, int command_id, cef_window_open_disposition_t) override {
    NC_CEF_CALLBACK;
    return [w_ chromeCommand:command_id];
  }

 private:
  __weak NCWindow* w_;
  IMPLEMENT_REFCOUNTING(NCClient);
};

class NCViewDelegate : public CefBrowserViewDelegate {
 public:
  explicit NCViewDelegate(NCWindow* w) : w_(w) {}
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  // Noche draws its own toolbar; the engine's stays off.
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  void OnBrowserCreated(CefRefPtr<CefBrowserView> v, CefRefPtr<CefBrowser> b) override {
    NC_CEF_CALLBACK;
    [w_ browserCreated:v browser:b];
  }
  void OnBrowserDestroyed(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> b) override {
    NC_CEF_CALLBACK;
    [w_ devToolsGone:b];
  }
  void OnTabAdded(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> tab, bool active) override {
    NC_CEF_CALLBACK;
    [w_ tabAdded:tab active:active];
  }
  void OnActiveTabChanged(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> previous,
                          CefRefPtr<CefBrowser> active) override {
    NC_CEF_CALLBACK;
    [w_ activeTabChangedFrom:previous to:active];
  }

 private:
  __weak NCWindow* w_;
  IMPLEMENT_REFCOUNTING(NCViewDelegate);
};

class NCWindowDelegate_ : public CefWindowDelegate {
 public:
  explicit NCWindowDelegate_(NCWindow* w) : w_(w) {}
  void OnWindowCreated(CefRefPtr<CefWindow> w) override { NC_CEF_CALLBACK; [w_ cefWindowCreated:w]; }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { NC_CEF_CALLBACK; [w_ cefWindowDestroyed]; }
  void OnWindowBoundsChanged(CefRefPtr<CefWindow>, const CefRect&) override { NC_CEF_CALLBACK; [w_ applyMask]; }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }  // Noche draws the chrome (M1.1 Task 4)
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return [w_ cefInitialBounds]; }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }

 private:
  __weak NCWindow* w_;
  IMPLEMENT_REFCOUNTING(NCWindowDelegate_);
};

}  // namespace

@implementation NCWindow {
  __weak id<NCWindowDelegate> _delegate;
  NSString* _url;
  NSRect _frame;
  NCWindowMode _mode;
  CefRefPtr<NCClient> _client;
  CefRefPtr<CefBrowserView> _view;
  CefRefPtr<CefWindow> _window;
  NSMutableDictionary<NSNumber*, NCTab*>* _table;
  NSMutableSet<NSNumber*>* _closed;  // identifiers whose OnBeforeClose ran: a late callback must not bring them back
  BOOL _destroyed, _windowClosing;
  int _devtoolsPending;  // OnBeforeDevToolsPopup seen, its browser not created yet (tells DevTools from window.open popups)
  NSMutableSet<NSNumber*>* _devtools;  // popup browsers of this window (DevTools), until their OnBeforeClose
  NSWindow* _nsWindow;
  BOOL _firstEmitted, _closeRequested;
  NSEdgeInsets _webInsets;
  CGFloat _webCornerRadius;
  CAShapeLayer* _mask;
}

@synthesize nsWindow = _nsWindow;
@synthesize webInsets = _webInsets, webCornerRadius = _webCornerRadius;

- (instancetype)initWithURL:(NSString*)url frame:(NSRect)frame mode:(NCWindowMode)mode delegate:(id<NCWindowDelegate>)delegate {
  if ((self = [super init])) {
    _url = [url copy];
    _frame = frame;
    _mode = mode;
    _delegate = delegate;
    _table = [NSMutableDictionary dictionary];
    _devtools = [NSMutableSet set];
    _closed = [NSMutableSet set];
    _client = new NCClient(self);
    _view = CefBrowserView::CreateBrowserView(_client, url.UTF8String, TabSettings(), nullptr, nullptr,
                                              new NCViewDelegate(self));
    CefWindow::CreateTopLevelWindow(new NCWindowDelegate_(self));
  }
  return self;
}

- (NSView*)chromeHost {
  return _nsWindow.contentView.superview;
}

- (CefRect)cefInitialBounds {
  return CefRect((int)_frame.origin.x, (int)_frame.origin.y, (int)_frame.size.width, (int)_frame.size.height);
}

// Runs |block| on the main thread after the CEF callback that caused it, in order.
- (void)post:(void (^)(id<NCWindowDelegate>))block {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (id<NCWindowDelegate> d = self->_delegate) block(d);
  });
}

- (NCTab*)tabFor:(CefRefPtr<CefBrowser>)b create:(BOOL)create {
  if (!b) return nil;
  NSNumber* key = @(b->GetIdentifier());
  NCTab* t = _table[key];
  const BOOL filtered = !NC_TEST_FLAG("NOCHE_TEST_NO_CLOSED_FILTER");  // negative control for no-zombie-tab
  if (!t && create && (!filtered || (!_destroyed && ![_closed containsObject:key]))) {
    t = [NCTab tabWithBrowser:b];
    _table[key] = t;
  }
  return t;
}

- (NSInteger)devToolsCount {
  NSInteger n = 0;
  for (NCTab* t in _table.allValues)
    if (t.browser && t.browser->GetHost()->HasDevTools()) n++;
  return n;
}

- (NSArray<NCTab*>*)tabs {
  NSMutableArray* out = [NSMutableArray array];
  if (_view) {
    std::vector<CefRefPtr<CefBrowser>> v;
    _view->GetTabs(v);
    for (auto& b : v)
      if (NCTab* t = [self tabFor:b create:NO]) [out addObject:t];
  }
  return out;
}

- (NCTab*)activeTab {
  return _view ? [self tabFor:_view->GetActiveTab() create:NO] : nil;
}

- (NCTab*)addTabWithURL:(NSString*)url activate:(BOOL)activate {
  if (!_view) return nil;
  CefRefPtr<CefBrowser> b = _view->AddTab(url.UTF8String, nullptr, TabSettings(), nullptr, activate);
  return [self tabFor:b create:YES];
}

- (void)activateTab:(NCTab*)tab {
  if (_view && tab.browser) _view->SetActiveTab(tab.browser);
}

- (void)close {
  if (!_window) { _closeRequested = YES; return; }
  // DevTools browsers go first; the window closes once they are gone (the cap covers one that never reports).
  if (NC_TEST_FLAG("NOCHE_TEST_DEVTOOLS_LAST")) {  // negative control: the tabs close first, as before this fix
    [self closeWindowNow];
    return;
  }
  for (NCTab* t in _table.allValues)
    if (t.browser && t.browser->GetHost()->HasDevTools()) t.browser->GetHost()->CloseDevTools();
  [self closeWindowWhenDevToolsGone:40];
}

- (void)closeWindowWhenDevToolsGone:(int)left {
  if (!_window) return;
  if (self.devToolsCount > 0 || _devtools.count > 0) {
    // Past the cap: say so (the checks fail on this line) and keep waiting; the app's 5 s watchdog ends it.
    if (left == 0) fprintf(stderr, "NOCHE devtools still open after 2 s, window not closed early\n");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 20), dispatch_get_main_queue(), ^{ [self closeWindowWhenDevToolsGone:MAX(left - 1, -1)]; });
    return;
  }
  [self closeWindowNow];
}

- (void)closeWindowNow {
  if (!_window || _windowClosing) return;
  _windowClosing = YES;
  _window->Close();
}

// MARK: web view rect and corner mask

- (void)setWebInsets:(NSEdgeInsets)insets {
  _webInsets = insets;
  [self applyLayout];
}

- (void)setWebCornerRadius:(CGFloat)radius {
  _webCornerRadius = radius;
  [self applyMask];
}

// Views overrides SetBounds on the browser view (spike S1), so the rect is the window's box layout inside border.
- (void)applyLayout {
  if (!_window || !_view) return;
  CefBoxLayoutSettings st;
  st.horizontal = true;
  st.inside_border_insets = CefInsets((int)lround(_webInsets.top), (int)lround(_webInsets.left),
                                      (int)lround(_webInsets.bottom), (int)lround(_webInsets.right));
  st.cross_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH;
  CefRefPtr<CefBoxLayout> bl = _window->SetToBoxLayout(st);
  bl->SetFlexForView(_view, 1);
  _window->Layout();
  [self applyMask];
}

static NSView* FindByClass(NSView* v, NSString* cls) {
  if ([NSStringFromClass(v.class) isEqualToString:cls]) return v;
  for (NSView* s in v.subviews)
    if (NSView* r = FindByClass(s, cls)) return r;
  return nil;
}

// The page draws through ViewsCompositorSuperview, not the web view's own layer (spike S1, C6), so the bottom corner
// rounding is a CAShapeLayer mask on that layer. The path is built in window base coordinates (origin bottom-left) and
// mapped into the mask's space with AppKit and Core Animation's own conversions, so flipped layers cannot mirror it.
- (void)applyMask {
  NSView* host = self.chromeHost;
  NSView* csv = host ? FindByClass(host, @"ViewsCompositorSuperview") : nil;
  if (!csv) return;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  csv.wantsLayer = YES;
  if (_webCornerRadius <= 0) {
    csv.layer.mask = nil;
    _mask = nil;
  } else {
    if (!_mask) _mask = [CAShapeLayer layer];
    _mask.frame = csv.layer.bounds;
    csv.layer.mask = _mask;
    NSRect content = [_nsWindow.contentView convertRect:_nsWindow.contentView.bounds toView:nil];
    const CGFloat x = NSMinX(content) + _webInsets.left, y = NSMinY(content) + _webInsets.bottom;
    const CGFloat w = content.size.width - _webInsets.left - _webInsets.right;
    const CGFloat h = content.size.height - _webInsets.top - _webInsets.bottom;
    const CGFloat r = MIN(_webCornerRadius, MIN(w, h) / 2);
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, nullptr, x + r, y);  // bottom edge, then up the right side
    CGPathAddArc(path, nullptr, x + w - r, y + r, r, -M_PI_2, 0, false);
    CGPathAddLineToPoint(path, nullptr, x + w, y + h);
    CGPathAddLineToPoint(path, nullptr, x, y + h);
    CGPathAddLineToPoint(path, nullptr, x, y + r);
    CGPathAddArc(path, nullptr, x + r, y + r, r, M_PI, 3 * M_PI_2, false);
    CGPathCloseSubpath(path);
    // base -> mask space is affine: map the origin and the unit vectors.
    CGPoint o = [self maskPointForWindowPoint:CGPointZero];
    CGPoint ex = [self maskPointForWindowPoint:CGPointMake(1, 0)];
    CGPoint ey = [self maskPointForWindowPoint:CGPointMake(0, 1)];
    CGAffineTransform t = CGAffineTransformMake(ex.x - o.x, ex.y - o.y, ey.x - o.x, ey.y - o.y, o.x, o.y);
    CGPathRef mapped = CGPathCreateCopyByTransformingPath(path, &t);
    _mask.path = mapped;
    CGPathRelease(mapped);
    CGPathRelease(path);
  }
  [CATransaction commit];
}

- (CGPoint)maskPointForWindowPoint:(CGPoint)p {
  NSView* csv = FindByClass(self.chromeHost, @"ViewsCompositorSuperview");
  NSPoint v = [csv convertPoint:p fromView:nil];  // view coordinates equal layer coordinates for a layer-backed view
  return [_mask convertPoint:v fromLayer:csv.layer];
}

static NSView* FindVisible(NSView* v, NSString* cls) {
  if ([NSStringFromClass(v.class) isEqualToString:cls] && !v.isHiddenOrHasHiddenAncestor) return v;
  for (NSView* s in v.subviews)
    if (NSView* r = FindVisible(s, cls)) return r;
  return nil;
}

// The view that shows the page: WebContentsViewCocoa, the visible one when several tabs exist.
- (NSView*)webView {
  NSView* host = self.chromeHost;
  if (!host) return nil;
  return FindVisible(host, @"WebContentsViewCocoa");
}

- (BOOL)webMaskExists {
  return _mask && _mask.path && _mask.superlayer != nil;
}

- (BOOL)webMaskContainsWindowPoint:(NSPoint)p {
  if (![self webMaskExists]) return NO;
  CGPoint m = [self maskPointForWindowPoint:p];
  return CGPathContainsPoint(_mask.path, nullptr, m, false);
}

// MARK: CEF callbacks (UI thread)

- (void)cefWindowCreated:(CefRefPtr<CefWindow>)w {
  _window = w;
  w->AddChildView(_view);
  _nsWindow = ((__bridge NSView*)w->GetWindowHandle()).window;
  if (!g_own_windows) g_own_windows = [NSHashTable weakObjectsHashTable];
  [g_own_windows addObject:_nsWindow];
  if (_mode == NCWindowModeHidden) {
    // Invisible and inert: alpha 0 before anything draws, click-through, never key, never shown through
    // CefWindow::Show (its kShowAndActivateWindow ends in an app activation).
    _nsWindow.alphaValue = 0;
    _nsWindow.ignoresMouseEvents = YES;
    [self orderInHidden:25];
  } else {
    w->Show();
  }
  [self applyLayout];
  if (_closeRequested) [self close];
}

// Ordering the NSWindow in does not make the views::Widget visible on its own; ordering it again once it is on
// screen does (engine probe, EnsureWindowVisible). Orders without makeKey, so the app never activates.
- (void)orderInHidden:(int)left {
  if (!_window || !_nsWindow) return;
  _nsWindow.level = NSFloatingWindowLevel;
  _nsWindow.ignoresMouseEvents = YES;
  [_nsWindow orderWindow:NSWindowAbove relativeTo:0];
  if (_window->IsVisible() || left <= 0) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{
    [self orderInHidden:left - 1];
  });
}

- (void)cefWindowDestroyed {
  _destroyed = YES;
  _window = nullptr;
  _view = nullptr;
  _nsWindow = nil;
  // Tabs whose OnBeforeClose did not arrive before the window went: report them closed so the host's list stays true.
  NSArray<NCTab*>* left = _table.allValues;
  [_table removeAllObjects];
  for (NCTab* t in left) {
    [t browserClosed];
    [self post:^(id<NCWindowDelegate> d) { [d window:self didCloseTab:t]; }];
  }
  [self post:^(id<NCWindowDelegate> d) { [d windowDidClose:self]; }];
}

- (void)browserCreated:(CefRefPtr<CefBrowserView>)view browser:(CefRefPtr<CefBrowser>)browser {
  // Popup views (DevTools) report to the same delegate; only this window's view makes tabs. The first
  // OnBrowserCreated can fire before CreateBrowserView returned, so _view may still be unset.
  if (_destroyed) return;
  if (_view && !view->IsSame(_view)) {
    // Only DevTools popups count (not window.open ones): the ones OnBeforeDevToolsPopup announced.
    if (_devtoolsPending > 0) {
      _devtoolsPending--;
      [_devtools addObject:@(browser->GetIdentifier())];
      g_devtools_created++;
      g_devtools_browsers[browser->GetIdentifier()] = browser;
    }
    return;
  }
  NCTab* tab = [self tabFor:browser create:YES];
  if (_firstEmitted) return;  // later tabs are announced by OnTabAdded
  _firstEmitted = YES;
  [self post:^(id<NCWindowDelegate> d) { [d window:self didAddTab:tab active:YES]; }];
}

- (void)devToolsAbout:(CefRefPtr<CefBrowser>)browser {
  _devtoolsPending++;
}

// A DevTools browser ended (OnBeforeClose or the view's OnBrowserDestroyed, whichever comes first).
- (void)devToolsGone:(CefRefPtr<CefBrowser>)browser {
  NSNumber* key = @(browser->GetIdentifier());
  if (![_devtools containsObject:key]) return;
  [_devtools removeObject:key];
  g_devtools_closed++;
  g_devtools_browsers.erase(browser->GetIdentifier());
}

- (void)tabAdded:(CefRefPtr<CefBrowser>)browser active:(BOOL)active {
  NCTab* tab = [self tabFor:browser create:YES];
  if (tab) [self post:^(id<NCWindowDelegate> d) { [d window:self didAddTab:tab active:active]; }];
}

- (void)activeTabChangedFrom:(CefRefPtr<CefBrowser>)previous to:(CefRefPtr<CefBrowser>)active {
  NCTab* tab = [self tabFor:active create:YES];
  NCTab* prev = [self tabFor:previous create:NO];
  if (tab) [self post:^(id<NCWindowDelegate> d) { [d window:self didActivateTab:tab previous:prev]; }];
}

// OnBeforeClose reaches every tab, the last one included (OnTabClosed is skipped once the view is gone).
- (void)browserClosing:(CefRefPtr<CefBrowser>)browser {
  NSNumber* key = @(browser->GetIdentifier());
  [_closed addObject:key];
  if ([_devtools containsObject:key]) {
    [self devToolsGone:browser];
    return;
  }
  NCTab* tab = _table[key];
  if (!tab) return;
  [_table removeObjectForKey:key];
  [tab browserClosed];
  [self post:^(id<NCWindowDelegate> d) { [d window:self didCloseTab:tab]; }];
  if (NC_TEST_FLAG("NOCHE_TEST_LATE_CALLBACKS")) {  // simulates CEF's late async OnTabAdded / OnActiveTabChanged
    dispatch_async(dispatch_get_main_queue(), ^{
      [self tabAdded:browser active:YES];
      [self activeTabChangedFrom:nullptr to:browser];
    });
  }
}

- (void)browser:(CefRefPtr<CefBrowser>)browser update:(void (^)(NCTab*))mutate {
  NCTab* tab = [self tabFor:browser create:NO];
  if (!tab) return;
  mutate(tab);
  [self post:^(id<NCWindowDelegate> d) { [d window:self didUpdateTab:tab]; }];
}

- (void)browser:(CefRefPtr<CefBrowser>)browser finishedLoadWithStatus:(int)status {
  NCTab* tab = [self tabFor:browser create:NO];
  if (tab) [self post:^(id<NCWindowDelegate> d) { [d window:self tab:tab didFinishLoadWithStatus:status]; }];
}

- (void)browser:(CefRefPtr<CefBrowser>)browser failedLoadWithCode:(int)code url:(NSString*)url {
  NCTab* tab = [self tabFor:browser create:NO];
  if (tab) [self post:^(id<NCWindowDelegate> d) { [d window:self tab:tab didFailLoadWithCode:code url:url]; }];
}

- (void)browser:(CefRefPtr<CefBrowser>)browser faviconURLs:(const std::vector<CefString>&)urls {
  NCTab* tab = [self tabFor:browser create:NO];
  if (!tab || urls.empty()) return;
  [tab loadFaviconFromURL:@(urls[0].ToString().c_str()) done:^{
    if (!tab.browser || self->_table[@(tab.identifier)] != tab) return;  // closed meanwhile
    [self post:^(id<NCWindowDelegate> d) { [d window:self didUpdateTab:tab]; }];
  }];
}

- (BOOL)chromeCommand:(int)commandId {
  id<NCWindowDelegate> d = _delegate;
  return d && [d window:self shouldHandleChromeCommand:commandId];
}

// MARK: hidden-mode guards

// Copied from the engine probe (Probes/EngineProbe/main.mm, alpha guard and activation guard). Chromium can order a
// window in at alpha 1 on first show and the Web Store install ends in [NSApp activateIgnoringOtherApps:YES], so
// alpha is clamped to 0, each order-in zeroes alpha first, and every activation call is a counted no-op.
static NSInteger g_activate_blocked = 0;
static NSInteger g_alpha_attempts_own = 0, g_alpha_attempts_other = 0;
static NSHashTable<NSWindow*>* g_own_windows;  // NCWindow windows, weak
static void (*orig_setAlpha)(id, SEL, CGFloat);
static void (*orig_orderWindow)(id, SEL, NSWindowOrderingMode, NSInteger);
static void (*orig_orderFront)(id, SEL, id);
static void (*orig_orderBack)(id, SEL, id);
static void (*orig_orderFrontRegardless)(id, SEL);
static void (*orig_makeKeyAndOrderFront)(id, SEL, id);
static void (*orig_beginSheet)(id, SEL, NSWindow*, id);

static void GuardWindow(id w) {
  orig_setAlpha(w, @selector(setAlphaValue:), 0);
  [(NSWindow*)w setIgnoresMouseEvents:YES];
}
// An attempt to set alpha above 0 is counted, and clamped. Ours are counted apart: nothing may try to show one of our windows
// (Chromium's own order-in at alpha 1 goes through the order swizzles, not here, and is not an attempt on setAlphaValue:).
static void swz_setAlpha(id self, SEL c, CGFloat a) {
  if (a > 0) {
    if ([g_own_windows containsObject:self]) g_alpha_attempts_own++; else g_alpha_attempts_other++;
  }
  orig_setAlpha(self, c, 0);
}
static void swz_orderWindow(id self, SEL c, NSWindowOrderingMode m, NSInteger r) { GuardWindow(self); orig_orderWindow(self, c, m, r); }
static void swz_orderFront(id self, SEL c, id a) { GuardWindow(self); orig_orderFront(self, c, a); }
static void swz_orderBack(id self, SEL c, id a) { GuardWindow(self); orig_orderBack(self, c, a); }
static void swz_orderFrontRegardless(id self, SEL c) { GuardWindow(self); orig_orderFrontRegardless(self, c); }
// Hidden mode never makes a window key: order it in without makeKey.
static void swz_makeKeyAndOrderFront(id self, SEL c, id a) { GuardWindow(self); orig_orderWindow(self, @selector(orderWindow:relativeTo:), NSWindowAbove, 0); }
static void swz_beginSheet(id self, SEL c, NSWindow* sheet, id handler) {
  GuardWindow(sheet);
  orig_beginSheet(self, c, sheet, handler);
}
static void swz_activateIgnoring(id, SEL, BOOL) { g_activate_blocked++; }
static void swz_activate(id, SEL) { g_activate_blocked++; }
static BOOL swz_activateWithOptions(id, SEL, NSApplicationActivationOptions) { g_activate_blocked++; return NO; }

template <typename F>
static void Swizzle(SEL sel, F** orig, F* repl) {
  Method m = class_getInstanceMethod(NSWindow.class, sel);
  *orig = (F*)method_getImplementation(m);
  method_setImplementation(m, (IMP)repl);
}

+ (void)installHiddenGuards {
  static BOOL installed = NO;
  if (installed) return;
  installed = YES;
  Swizzle(@selector(setAlphaValue:), &orig_setAlpha, swz_setAlpha);
  Swizzle(@selector(orderWindow:relativeTo:), &orig_orderWindow, swz_orderWindow);
  Swizzle(@selector(orderFront:), &orig_orderFront, swz_orderFront);
  Swizzle(@selector(orderBack:), &orig_orderBack, swz_orderBack);
  Swizzle(@selector(orderFrontRegardless), &orig_orderFrontRegardless, swz_orderFrontRegardless);
  Swizzle(@selector(makeKeyAndOrderFront:), &orig_makeKeyAndOrderFront, swz_makeKeyAndOrderFront);
  Swizzle(@selector(beginSheet:completionHandler:), &orig_beginSheet, swz_beginSheet);
  method_setImplementation(class_getInstanceMethod(NSApplication.class, @selector(activateIgnoringOtherApps:)), (IMP)swz_activateIgnoring);
  method_setImplementation(class_getInstanceMethod(NSApplication.class, @selector(activate)), (IMP)swz_activate);
  method_setImplementation(class_getInstanceMethod(NSRunningApplication.class, @selector(activateWithOptions:)), (IMP)swz_activateWithOptions);
  // Backstop: any window of this process at alpha > 0 is zeroed within 5 ms (common modes, so sheet animations are covered).
  NSTimer* t = [NSTimer timerWithTimeInterval:0.005 repeats:YES block:^(NSTimer*) {
    for (NSWindow* w in NSApp.windows)
      if (w.alphaValue != 0) GuardWindow(w);
  }];
  [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
}

#ifdef NOCHE_TESTHOOKS
+ (NSInteger)devToolsCreated { return g_devtools_created; }
+ (NSInteger)devToolsLoaded {
  for (auto& [id, b] : g_devtools_browsers)
    if (!b->IsLoading() && b->HasDocument()) g_devtools_loaded_ids.insert(id);
  return g_devtools_loaded_ids.size();
}
+ (NSInteger)devToolsClosed { return g_devtools_closed; }

+ (BOOL)insideCefCallback {
  return g_nc_cef_depth > 0;
}
#endif

+ (NSInteger)activationsBlocked {
  return g_activate_blocked;
}

+ (NSInteger)alphaAttemptsOnOwnWindows {
  return g_alpha_attempts_own;
}

+ (NSInteger)alphaAttemptsOnOtherWindows {
  return g_alpha_attempts_other;
}

@end
