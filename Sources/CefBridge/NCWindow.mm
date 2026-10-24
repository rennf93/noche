#import "CefBridge.h"
#import "NCTabInternal.h"
#import <objc/runtime.h>
#include "include/cef_client.h"
#include "include/cef_command_handler.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

@interface NCWindow ()
- (CefRect)cefInitialBounds;
- (void)cefWindowCreated:(CefRefPtr<CefWindow>)window;
- (void)cefWindowDestroyed;
- (void)browserCreated:(CefRefPtr<CefBrowserView>)view browser:(CefRefPtr<CefBrowser>)browser;
- (void)tabAdded:(CefRefPtr<CefBrowser>)browser active:(BOOL)active;
- (void)activeTabChangedFrom:(CefRefPtr<CefBrowser>)previous to:(CefRefPtr<CefBrowser>)active;
- (void)browserClosing:(CefRefPtr<CefBrowser>)browser;
- (void)browser:(CefRefPtr<CefBrowser>)browser update:(void (^)(NCTab*))mutate;
- (void)browser:(CefRefPtr<CefBrowser>)browser finishedLoadWithStatus:(int)status;
- (void)browser:(CefRefPtr<CefBrowser>)browser failedLoadWithCode:(int)code;
- (void)browser:(CefRefPtr<CefBrowser>)browser faviconURLs:(const std::vector<CefString>&)urls;
- (BOOL)chromeCommand:(int)commandId;
@end

namespace {

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

  void OnBeforeClose(CefRefPtr<CefBrowser> b) override { [w_ browserClosing:b]; }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> b, bool loading, bool back, bool forward) override {
    [w_ browser:b update:^(NCTab* t) {
      t.isLoading = loading;
      t.canGoBack = back;
      t.canGoForward = forward;
    }];
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, int status) override {
    if (f->IsMain()) [w_ browser:b finishedLoadWithStatus:status];
  }
  void OnLoadError(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, ErrorCode code, const CefString&,
                   const CefString&) override {
    if (f->IsMain() && code != ERR_ABORTED) [w_ browser:b failedLoadWithCode:(int)code];
  }
  void OnTitleChange(CefRefPtr<CefBrowser> b, const CefString& title) override {
    NSString* s = @(title.ToString().c_str());
    [w_ browser:b update:^(NCTab* t) { t.title = s; }];
  }
  void OnAddressChange(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, const CefString& url) override {
    if (!f->IsMain()) return;
    NSString* s = @(url.ToString().c_str());
    [w_ browser:b update:^(NCTab* t) { t.url = s; }];
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser> b, const std::vector<CefString>& urls) override {
    [w_ browser:b faviconURLs:urls];
  }
  bool OnChromeCommand(CefRefPtr<CefBrowser>, int command_id, cef_window_open_disposition_t) override {
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
    [w_ browserCreated:v browser:b];
  }
  void OnTabAdded(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> tab, bool active) override {
    [w_ tabAdded:tab active:active];
  }
  void OnActiveTabChanged(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> previous,
                          CefRefPtr<CefBrowser> active) override {
    [w_ activeTabChangedFrom:previous to:active];
  }

 private:
  __weak NCWindow* w_;
  IMPLEMENT_REFCOUNTING(NCViewDelegate);
};

class NCWindowDelegate_ : public CefWindowDelegate {
 public:
  explicit NCWindowDelegate_(NCWindow* w) : w_(w) {}
  void OnWindowCreated(CefRefPtr<CefWindow> w) override { [w_ cefWindowCreated:w]; }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { [w_ cefWindowDestroyed]; }
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
  NSWindow* _nsWindow;
  BOOL _firstEmitted, _closeRequested;
}

@synthesize nsWindow = _nsWindow;

- (instancetype)initWithURL:(NSString*)url frame:(NSRect)frame mode:(NCWindowMode)mode delegate:(id<NCWindowDelegate>)delegate {
  if ((self = [super init])) {
    _url = [url copy];
    _frame = frame;
    _mode = mode;
    _delegate = delegate;
    _table = [NSMutableDictionary dictionary];
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
  if (!t && create) {
    t = [NCTab tabWithBrowser:b];
    _table[key] = t;
  }
  return t;
}

- (NSArray<NCTab*>*)tabs {
  NSMutableArray* out = [NSMutableArray array];
  if (_view) {
    std::vector<CefRefPtr<CefBrowser>> v;
    _view->GetTabs(v);
    for (auto& b : v)
      if (NCTab* t = [self tabFor:b create:YES]) [out addObject:t];
  }
  return out;
}

- (NCTab*)activeTab {
  return _view ? [self tabFor:_view->GetActiveTab() create:YES] : nil;
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
  if (_window) _window->Close();
  else _closeRequested = YES;
}

// MARK: CEF callbacks (UI thread)

- (void)cefWindowCreated:(CefRefPtr<CefWindow>)w {
  _window = w;
  w->AddChildView(_view);
  _nsWindow = ((__bridge NSView*)w->GetWindowHandle()).window;
  if (_mode == NCWindowModeHidden) {
    // Invisible and inert: alpha 0 before anything draws, click-through, never key, never shown through
    // CefWindow::Show (its kShowAndActivateWindow ends in an app activation).
    _nsWindow.alphaValue = 0;
    _nsWindow.ignoresMouseEvents = YES;
    [self orderInHidden:25];
  } else {
    w->Show();
  }
  if (_closeRequested) w->Close();
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
  if (_view && !view->IsSame(_view)) return;
  NCTab* tab = [self tabFor:browser create:YES];
  if (_firstEmitted) return;  // later tabs are announced by OnTabAdded
  _firstEmitted = YES;
  [self post:^(id<NCWindowDelegate> d) { [d window:self didAddTab:tab active:YES]; }];
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
  NCTab* tab = _table[key];
  if (!tab) return;
  [_table removeObjectForKey:key];
  [tab browserClosed];
  [self post:^(id<NCWindowDelegate> d) { [d window:self didCloseTab:tab]; }];
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

- (void)browser:(CefRefPtr<CefBrowser>)browser failedLoadWithCode:(int)code {
  NCTab* tab = [self tabFor:browser create:NO];
  if (tab) [self post:^(id<NCWindowDelegate> d) { [d window:self tab:tab didFailLoadWithCode:code]; }];
}

- (void)browser:(CefRefPtr<CefBrowser>)browser faviconURLs:(const std::vector<CefString>&)urls {
  NCTab* tab = [self tabFor:browser create:NO];
  if (!tab || urls.empty()) return;
  [tab loadFaviconFromURL:@(urls[0].ToString().c_str()) done:^{
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
static void swz_setAlpha(id self, SEL c, CGFloat) { orig_setAlpha(self, c, 0); }
static void swz_orderWindow(id self, SEL c, NSWindowOrderingMode m, NSInteger r) { GuardWindow(self); orig_orderWindow(self, c, m, r); }
static void swz_orderFront(id self, SEL c, id a) { GuardWindow(self); orig_orderFront(self, c, a); }
static void swz_orderBack(id self, SEL c, id a) { GuardWindow(self); orig_orderBack(self, c, a); }
static void swz_orderFrontRegardless(id self, SEL c) { GuardWindow(self); orig_orderFrontRegardless(self, c); }
static void swz_makeKeyAndOrderFront(id self, SEL c, id a) { GuardWindow(self); orig_makeKeyAndOrderFront(self, c, a); }
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

+ (NSInteger)activationsBlocked {
  return g_activate_blocked;
}

@end
