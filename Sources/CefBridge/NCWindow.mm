#import "CefBridge.h"
#import "NCTabInternal.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#include <map>
#include <set>
#include "include/cef_client.h"
#include "include/cef_command_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_menu_model.h"
#include "include/cef_jsdialog_handler.h"
#include "include/views/cef_box_layout.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

@interface NCWindow ()
- (CefRect)cefInitialBounds;
- (void)applyMask;
- (NSArray<NSView*>*)visiblePageViews;
- (void)showWebContent;
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
- (void)browser:(CefRefPtr<CefBrowser>)browser mainFrameLoadStarted:(NSString*)url;
- (BOOL)chromeCommand:(int)commandId;
- (void)browser:(CefRefPtr<CefBrowser>)browser foundMatches:(int)count active:(int)ordinal final:(BOOL)final identifier:(int)identifier;
- (void)browser:(CefRefPtr<CefBrowser>)browser fullscreen:(BOOL)fullscreen;
- (BOOL)browser:(CefRefPtr<CefBrowser>)browser contextMenu:(CefRefPtr<CefMenuModel>)model x:(int)x y:(int)y callback:(CefRefPtr<CefRunContextMenuCallback>)callback;
- (BOOL)preemptKey:(NSEvent*)event;
+ (void)registerForKeyClaims:(NCWindow*)w;
- (void)unloadDialogResolved:(CefRefPtr<CefBrowser>)browser leaves:(BOOL)leaves;
- (void)unloadDialogClosed:(CefRefPtr<CefBrowser>)browser;
@end

@interface NCMenuItem ()
- (instancetype)initPrivate;
@property(nonatomic, readwrite) NSInteger commandId;
@property(nonatomic, readwrite, copy) NSString* label;
@property(nonatomic, readwrite) NCMenuItemType type;
@property(nonatomic, readwrite) BOOL enabled, visible, checked;
@property(nonatomic, readwrite, nullable) NSArray<NCMenuItem*>* submenu;
@end

@implementation NCMenuItem
- (instancetype)initPrivate { return [super init]; }
@end

namespace {

NSInteger g_devtools_created = 0, g_devtools_closed = 0;
#ifdef NOCHE_TESTHOOKS
NSInteger g_ctx_continues = 0, g_ctx_cancels = 0;
#endif
// DevTools has its own client, so its load end never reaches ours: loaded is read off the browser (polled by the checks).
std::map<int, CefRefPtr<CefBrowser>> g_devtools_browsers;
std::set<int> g_devtools_loaded_ids;
#ifdef NOCHE_TESTHOOKS
NSInteger g_unload_answer = 0, g_unload_dialogs = 0;
#endif

// "&Save As..." is Chromium's mnemonic marker: "&&" is a literal ampersand, a single "&" is dropped.
NSString* NCStripMnemonics(const std::string& label) {
  std::string out;  // '&' is ASCII, so a byte walk is safe on UTF-8
  for (size_t i = 0; i < label.size(); i++) {
    if (label[i] == '&') {
      if (i + 1 < label.size() && label[i + 1] == '&') { out += '&'; i++; }
      continue;
    }
    out += label[i];
  }
  return @(out.c_str());
}

// A copy of |m| as NCMenuItems; everything is read now because the model is gone once RunContextMenu returns.
NSArray<NCMenuItem*>* NCCopyMenu(CefRefPtr<CefMenuModel> m) {
  NSMutableArray<NCMenuItem*>* out = [NSMutableArray array];
  for (size_t i = 0; i < m->GetCount(); i++) {
    NCMenuItem* item = [[NCMenuItem alloc] initPrivate];
    item.commandId = m->GetCommandIdAt(i);
    item.label = NCStripMnemonics(m->GetLabelAt(i).ToString());
    item.enabled = m->IsEnabledAt(i);
    item.visible = m->IsVisibleAt(i);
    item.checked = m->IsCheckedAt(i);
    switch (m->GetTypeAt(i)) {
      case MENUITEMTYPE_CHECK: item.type = NCMenuItemTypeCheck; break;
      case MENUITEMTYPE_RADIO: item.type = NCMenuItemTypeRadio; break;
      case MENUITEMTYPE_SEPARATOR: item.type = NCMenuItemTypeSeparator; break;
      case MENUITEMTYPE_SUBMENU:
        item.type = NCMenuItemTypeSubmenu;
        if (CefRefPtr<CefMenuModel> sub = m->GetSubMenuAt(i)) item.submenu = NCCopyMenu(sub);
        break;
      default: item.type = NCMenuItemTypeCommand; break;
    }
    [out addObject:item];
  }
  return out;
}

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
                 public CefCommandHandler,
                 public CefContextMenuHandler,
                 public CefFindHandler,
                 public CefJSDialogHandler {
 public:
  explicit NCClient(NCWindow* w) : w_(w) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }

  void OnFindResult(CefRefPtr<CefBrowser> b, int identifier, int count, const CefRect&, int ordinal, bool final) override {
    NC_CEF_CALLBACK;
    [w_ browser:b foundMatches:count active:ordinal final:final identifier:identifier];
  }

  // The page menu is Noche's: the model is copied inside this call (it must not outlive it) and the host shows an NSMenu.
  bool RunContextMenu(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> p, CefRefPtr<CefMenuModel> m,
                      CefRefPtr<CefRunContextMenuCallback> callback) override {
    NC_CEF_CALLBACK;
    return [w_ browser:b contextMenu:m x:p->GetXCoord() y:p->GetYCoord() callback:callback];
  }

  // Chrome shows its own "Leave site?" dialog (return false). The bridge only learns how it ended: a tab that is still there
  // after the dialog closed was told to stay. Test builds can answer the dialog themselves.
  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> b, const CefString&, bool, CefRefPtr<CefJSDialogCallback> callback) override {
    NC_CEF_CALLBACK;
#ifdef NOCHE_TESTHOOKS
    g_unload_dialogs++;
    if (g_unload_answer != 0) {
      const bool leaves = g_unload_answer == 2;
      callback->Continue(leaves, CefString());
      [w_ unloadDialogResolved:b leaves:leaves];
      return true;
    }
#endif
    return false;
  }
  void OnDialogClosed(CefRefPtr<CefBrowser> b) override { NC_CEF_CALLBACK; [w_ unloadDialogClosed:b]; }

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
  void OnLoadStart(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, TransitionType) override {
    NC_CEF_CALLBACK;
    if (f->IsMain()) [w_ browser:b mainFrameLoadStarted:@(f->GetURL().ToString().c_str())];
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
  void OnFullscreenModeChange(CefRefPtr<CefBrowser> b, bool fullscreen) override {
    NC_CEF_CALLBACK;
    [w_ browser:b fullscreen:fullscreen];
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
  BOOL _destroyed, _windowClosing, _waitingForDevTools;
  int _devtoolsPending;  // OnBeforeDevToolsPopup seen, its browser not created yet (tells DevTools from window.open popups)
  NSMutableSet<NSNumber*>* _devtools;  // popup browsers of this window (DevTools), until their OnBeforeClose
  NSWindow* _nsWindow;
  BOOL _firstEmitted, _closeRequested;
  NSEdgeInsets _webInsets;
  CGFloat _webCornerRadius;
  BOOL _webContentHidden;
  CAShapeLayer* _mask;
  // What the layout and the mask were last built from, so the same inputs build nothing (the sidebar motion sets insets every tick).
  CefInsets _layoutInsets;
  BOOL _layoutBuilt;
  NSRect _maskKey;
  CGFloat _maskRadius;
  NSInteger _layoutPasses, _maskPasses, _ambiguousFocusLogs;
}

@synthesize nsWindow = _nsWindow;
@synthesize webContentHidden = _webContentHidden, webInsets = _webInsets, webCornerRadius = _webCornerRadius;
#ifdef NOCHE_TESTHOOKS
- (NSInteger)testLayoutPasses { return _layoutPasses; }
- (NSInteger)testMaskPasses { return _maskPasses; }
- (NSInteger)testAmbiguousFocusLogs { return _ambiguousFocusLogs; }
#endif

- (instancetype)initWithURL:(NSString*)url frame:(NSRect)frame mode:(NCWindowMode)mode delegate:(id<NCWindowDelegate>)delegate {
  if ((self = [super init])) {
    _url = [url copy];
    _frame = frame;
    _mode = mode;
    _delegate = delegate;
    _table = [NSMutableDictionary dictionary];
    _devtools = [NSMutableSet set];
    _closed = [NSMutableSet set];
    [NCWindow registerForKeyClaims:self];
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

// The one conversion between the two coordinate conventions at this boundary: NCWindow takes AppKit global coordinates
// (origin at the bottom-left of the primary screen, y up, the space NSWindow.frame is in); CEF Views takes DIPs with the origin
// at the top-left of the primary screen, y down. x, width and height are equal in both, y flips about the primary screen height.
- (CefRect)cefInitialBounds {
  NSScreen* primary = NSScreen.screens.firstObject;  // the screen with the menu bar; its frame origin is (0, 0)
  const CGFloat top = primary ? primary.frame.size.height - NSMaxY(_frame) : _frame.origin.y;
  return CefRect((int)lround(_frame.origin.x), (int)lround(top), (int)lround(_frame.size.width), (int)lround(_frame.size.height));
}

// Runs |block| on the main thread after the CEF callback that caused it, in order.
- (void)post:(void (^)(id<NCWindowDelegate>))block {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (id<NCWindowDelegate> d = self->_delegate) block(d);
  });
}

// RunContextMenu: x and y are DIPs from the page view's top-left. Returns NO (Chromium shows its own menu) when the tab or host is gone.
- (BOOL)browser:(CefRefPtr<CefBrowser>)b contextMenu:(CefRefPtr<CefMenuModel>)m x:(int)x y:(int)y callback:(CefRefPtr<CefRunContextMenuCallback>)callback {
  NCTab* tab = [self tabFor:b create:NO];
  if (!tab || !_delegate || !_nsWindow) return NO;
  NSArray<NCMenuItem*>* items = NCCopyMenu(m);
  NSPoint point;
  if (NSView* page = self.webView) {
    point = [page convertPoint:NSMakePoint(x, page.isFlipped ? y : page.bounds.size.height - y) toView:nil];
  } else {
    NSView* content = _nsWindow.contentView;
    point = NSMakePoint(_webInsets.left + x, content.bounds.size.height - _webInsets.top - y);
  }
  // The one completion every path ends in: Continue or Cancel on the saved callback, exactly once, explicitly.
  __block BOOL answered = NO;
  void (^complete)(NSInteger) = [^(NSInteger commandId) {
    if (answered) return;
    answered = YES;
#ifdef NOCHE_TESTHOOKS
    if (commandId < 0) g_ctx_cancels++; else g_ctx_continues++;
#endif
    if (commandId < 0) callback->Cancel(); else callback->Continue((int)commandId, EVENTFLAG_NONE);
  } copy];
  dispatch_async(dispatch_get_main_queue(), ^{
    id<NCWindowDelegate> d = self->_delegate;
    if (!d) { complete(-1); return; }  // no host left to show the menu
    [d window:self tab:tab showContextMenu:items atWindowPoint:point completion:complete];
  });
  return YES;
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
  if (activate) [self showWebContent];
  CefRefPtr<CefBrowser> b = _view->AddTab(url.UTF8String, nullptr, TabSettings(), nullptr, activate);
  return [self tabFor:b create:YES];
}

- (void)activateTab:(NCTab*)tab {
  [self showWebContent];
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
  [self closeWindowWhenDevToolsGone:200];
}

// Same bounds as NCTab's close: 50 ms polls for up to 10 s, then a NOCHE line and a wait for -devToolsGone:. Never closes early.
- (void)closeWindowWhenDevToolsGone:(int)left {
  if (!_window) return;
  if (self.devToolsCount > 0 || _devtools.count > 0) {
    if (left == 160) fprintf(stderr, "NOCHE devtools still open after 2 s, window not closed early\n");  // the checks fail on this line
    if (left == 0) {
      fprintf(stderr, "NOCHE devtools still open after 10 s, window close waits for the DevTools to end\n");
      _waitingForDevTools = YES;
      return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 20), dispatch_get_main_queue(), ^{ [self closeWindowWhenDevToolsGone:left - 1]; });
    return;
  }
  _waitingForDevTools = NO;
  [self closeWindowNow];
}

- (void)closeWindowNow {
  if (!_window || _windowClosing) return;
  _windowClosing = YES;
#ifdef NOCHE_TESTHOOKS
  // Test only: close the tabs one at a time, |ms| apart, so a quit takes long while every step is quick (the app's quit
  // watchdog must measure progress, not the total).
  if (const int ms = NCTestInt("NOCHE_TEST_SLOW_CLOSE_MS")) {
    NSArray<NCTab*>* all = _table.allValues;
    for (NSUInteger k = 0; k < all.count; k++) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(k * ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ [all[k] close]; });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((all.count + 1) * ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
      if (self->_window) self->_window->Close();
    });
    return;
  }
#endif
  _window->Close();
}

// MARK: web view rect and corner mask

- (void)setWebInsets:(NSEdgeInsets)insets {
  _webInsets = insets;
  [self applyLayout];
}

// The Views view's visibility, not the layer: the WebContents stays attached and visible to CEF's lifecycle checks as before.
- (void)setWebContentHidden:(BOOL)hidden {
  if (NC_TEST_FLAG("NOCHE_TEST_NO_HIDE")) return;  // negative control: the page view never hides
  _webContentHidden = hidden;
  if (!_view) return;
  _view->SetVisible(!hidden);
  if (_window) _window->Layout();
}

// Any switch of the active tab shows the page again (rule R13): the caller sets the flag again for a tab that wants it hidden.
- (void)showWebContent {
  if (NC_TEST_FLAG("NOCHE_TEST_NO_UNHIDE")) return;  // negative control: a switch leaves the view hidden
  if (_webContentHidden) [self setWebContentHidden:NO];
}

- (void)focusActiveContent {
  if (NC_TEST_FLAG("NOCHE_TEST_NO_FOCUS")) return;  // negative control: focus stays where it is
  if (!_view) return;
  _view->RequestFocus();
  if (CefRefPtr<CefBrowser> b = _view->GetActiveTab()) b->GetHost()->SetFocus(true);
  // Views records the focus but leaves AppKit's first responder alone while the window is not key (hidden runs, a window
  // behind another): then the page's own responder takes it, as content would on a key window.
  // Guard: with more than one visible WebContentsViewCocoa (a docked DevTools; nothing forces DevTools into its own window,
  // it did open as one in focus-return) the active tab's view cannot be identified reliably, and CefBrowserHost::GetWindowHandle
  // returns the window's content view, not the page's. Then the responder stays and one line says so; the Views focus above
  // still applies. One candidate missing (a crashed or loading renderer) also leaves the responder: Views focus still applies.
  NSUInteger count = [self visiblePageViews].count;
#ifdef NOCHE_TESTHOOKS
  if (const int forced = NCTestInt("NOCHE_TEST_PAGE_VIEWS")) count = (NSUInteger)forced;  // makes the candidate count read N
#endif
  if (count > 1 && !NC_TEST_FLAG("NOCHE_TEST_NO_AMBIGUOUS_GUARD")) {  // the flag is a negative control: no guard
    fprintf(stderr, "NOCHE focus ambiguous: %lu page views\n", (unsigned long)count);
#ifdef NOCHE_TESTHOOKS
    _ambiguousFocusLogs++;
#endif
    return;
  }
  NSView* page = self.webView;
  NSResponder* r = _nsWindow.firstResponder;
  if (page && !([r isKindOfClass:NSView.class] && [(NSView*)r isDescendantOf:page])) {
    NSView* target = FindByClass(page, @"RenderWidgetHostViewCocoa");
    if (target) [_nsWindow makeFirstResponder:target];
  }
}

- (void)setWebCornerRadius:(CGFloat)radius {
  _webCornerRadius = radius;
  [self applyMask];
}

// Views overrides SetBounds on the browser view (spike S1), so the rect is the window's box layout inside border.
// CEF has no way to change a box layout's insets after the fact (CefBoxLayoutSettings only go in through SetToBoxLayout), so a
// changed inset needs a new layout; unchanged insets, which are most calls, build nothing.
// Tried instead: one layout built once, then CefView::SetInsets on the window plus Layout(). The content rect follows (web-insets
// and sidebar-toggle pass) but it is not cheaper: measured over one sidebar toggle round (3 toggles, about 10 changed-inset calls
// each), the rebuild costs a mean 1.39 ms per call (median 1.32 ms) and SetInsets plus Layout() 1.55 ms (median 1.53 ms), so the
// time is in Layout() itself, not in building the box layout. Kept the rebuild path.
- (void)applyLayout {
  if (!_window || !_view) return;
  const CefInsets insets((int)lround(_webInsets.top), (int)lround(_webInsets.left), (int)lround(_webInsets.bottom),
                         (int)lround(_webInsets.right));
  if (_layoutBuilt && insets == _layoutInsets) return;
  CefBoxLayoutSettings st;
  st.horizontal = true;
  st.inside_border_insets = insets;
  st.cross_axis_alignment = CEF_AXIS_ALIGNMENT_STRETCH;
  CefRefPtr<CefBoxLayout> bl = _window->SetToBoxLayout(st);
  bl->SetFlexForView(_view, 1);
  _window->Layout();
  _layoutInsets = insets;
  _layoutBuilt = YES;
  _layoutPasses++;
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
  // The path depends on the content rect, the insets, the radius and the layer's own size: the same again changes nothing.
  const NSRect key = NSMakeRect(_webInsets.left, _webInsets.bottom, _nsWindow.contentView.bounds.size.width - _webInsets.right,
                                _nsWindow.contentView.bounds.size.height - _webInsets.top);
  if (_mask && csv.layer.mask == _mask && _mask.path && NSEqualRects(key, _maskKey) && _webCornerRadius == _maskRadius &&
      CGRectEqualToRect(_mask.frame, csv.layer.bounds))
    return;
  if (_webCornerRadius > 0 || _mask) _maskPasses++;
  _maskKey = key;
  _maskRadius = _webCornerRadius;
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

static void CollectVisible(NSView* v, NSString* cls, NSMutableArray<NSView*>* out) {
  if ([NSStringFromClass(v.class) isEqualToString:cls] && !v.isHiddenOrHasHiddenAncestor) [out addObject:v];
  for (NSView* s in v.subviews) CollectVisible(s, cls, out);
}

- (NSArray<NSView*>*)visiblePageViews {
  NSMutableArray<NSView*>* out = [NSMutableArray array];
  if (NSView* host = self.chromeHost) CollectVisible(host, @"WebContentsViewCocoa", out);
  return out;
}

// The view that shows the page: WebContentsViewCocoa. Fail safe: with more than one visible (a docked DevTools next to the
// page) the active tab's own view cannot be told apart reliably, so nil rather than a guess.
- (NSView*)webView {
  NSArray<NSView*>* all = [self visiblePageViews];
  return all.count == 1 ? all.firstObject : nil;
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
  // A close that gave up polling picks up here (HasDevTools may lag a moment behind, so they poll again).
  // From a later turn: this runs inside the DevTools browser's teardown.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_waitingForDevTools) [self closeWindowWhenDevToolsGone:200];
    for (NCTab* t in self->_table.allValues) [t devToolsEnded];
  });
}

- (void)tabAdded:(CefRefPtr<CefBrowser>)browser active:(BOOL)active {
  NCTab* tab = [self tabFor:browser create:YES];
  if (tab) [self post:^(id<NCWindowDelegate> d) { [d window:self didAddTab:tab active:active]; }];
}

- (void)activeTabChangedFrom:(CefRefPtr<CefBrowser>)previous to:(CefRefPtr<CefBrowser>)active {
  [self showWebContent];
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

// A load of another page (not a reload, not a change of the #fragment) that ends without Chrome having sent an icon list has no
// icon: Chrome sends no empty list in that case, so the previous page's icon is cleared here, once the load is over.
- (void)browser:(CefRefPtr<CefBrowser>)browser mainFrameLoadStarted:(NSString*)url {
  NCTab* tab = [self tabFor:browser create:NO];
  if (!tab) return;
  NSString* bare = [url componentsSeparatedByString:@"#"].firstObject;
  tab.clearFaviconAtLoadEnd = ![bare isEqualToString:tab.lastLoadURL];
  tab.lastLoadURL = bare;
  tab.faviconListSeen = NO;
  [self post:^(id<NCWindowDelegate> d) { [d window:self tabDidCommitNewDocument:tab]; }];
}

- (void)browser:(CefRefPtr<CefBrowser>)browser finishedLoadWithStatus:(int)status {
  NCTab* tab = [self tabFor:browser create:NO];
  if (tab && tab.clearFaviconAtLoadEnd && !tab.faviconListSeen && tab.favicon) {
    [tab clearFavicon];
    [self post:^(id<NCWindowDelegate> d) { [d window:self didUpdateTab:tab]; }];
  }
  if (tab) tab.clearFaviconAtLoadEnd = NO;
  if (tab) [self post:^(id<NCWindowDelegate> d) { [d window:self tab:tab didFinishLoadWithStatus:status]; }];
}

- (void)browser:(CefRefPtr<CefBrowser>)browser foundMatches:(int)count active:(int)ordinal final:(BOOL)final identifier:(int)identifier {
  NCTab* tab = [self tabFor:browser create:NO];
  if (tab) [self post:^(id<NCWindowDelegate> d) { [d window:self tab:tab didFindMatches:count active:ordinal final:final identifier:identifier]; }];
}

- (void)browser:(CefRefPtr<CefBrowser>)browser fullscreen:(BOOL)fullscreen {
  if (NCTab* tab = [self tabFor:browser create:NO]) tab.isHTMLFullscreen = fullscreen;
}

- (void)browser:(CefRefPtr<CefBrowser>)browser failedLoadWithCode:(int)code url:(NSString*)url {
  NCTab* tab = [self tabFor:browser create:NO];
  if (tab) [self post:^(id<NCWindowDelegate> d) { [d window:self tab:tab didFailLoadWithCode:code url:url]; }];
}

- (void)browser:(CefRefPtr<CefBrowser>)browser faviconURLs:(const std::vector<CefString>&)urls {
  NCTab* tab = [self tabFor:browser create:NO];
  if (!tab) return;
  tab.faviconListSeen = YES;
  if (urls.empty()) {  // the page has no icon: the placeholder comes back, the previous page's icon does not stay
    if (!tab.favicon) { tab.faviconURL = nil; return; }
    [tab clearFavicon];
    [self post:^(id<NCWindowDelegate> d) { [d window:self didUpdateTab:tab]; }];
    return;
  }
  tab.faviconURL = @(urls[0].ToString().c_str());
  [tab loadFaviconFromURL:@(urls[0].ToString().c_str()) done:^{
    if (!tab.browser || self->_table[@(tab.identifier)] != tab) return;  // closed meanwhile
    [self post:^(id<NCWindowDelegate> d) { [d window:self didUpdateTab:tab]; }];
  }];
}

// A beforeunload dialog answered Stay: the close the host asked for will not happen.
- (void)unloadDialogResolved:(CefRefPtr<CefBrowser>)browser leaves:(BOOL)leaves {
  if (leaves) return;
  NCTab* tab = [self tabFor:browser create:NO];
  if (!tab || !tab.closeRequested) return;
  tab.closeRequested = NO;
  [self post:^(id<NCWindowDelegate> d) { [d window:self didCancelCloseOfTab:tab]; }];
}

// Chrome's own dialog closed, and how is not reported: Leave ends the tab (OnBeforeClose) within a moment, Stay does not.
- (void)unloadDialogClosed:(CefRefPtr<CefBrowser>)browser {
  NCTab* tab = [self tabFor:browser create:NO];
  if (!tab || !tab.closeRequested) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (tab.browser && self->_table[@(tab.identifier)] == tab) [self unloadDialogResolved:tab.browser leaves:NO];
  });
}

#ifdef NOCHE_TESTHOOKS
extern NSInteger g_stop_find_calls;
static NSInteger g_preempted = 0;
+ (NSInteger)testContextMenuContinues { return g_ctx_continues; }
+ (NSInteger)testContextMenuCancels { return g_ctx_cancels; }
+ (NSInteger)testPreemptedKeys { return g_preempted; }
+ (NSInteger)testStopFindCalls { return g_stop_find_calls; }
#endif

// The one place the claimed chords are listed. Source: chrome/browser/global_keyboard_shortcuts_mac.mm (GetShortcutsNotPresentInMainMenu rows, lines 87 to 174;
// the matcher is -[NSMenuItem cr_firesForKeyEquivalentEvent:] in ui/base/cocoa/nsmenuitem_additions.mm, which clears Shift for printable keys and
// compares the rest of the modifiers exactly). A chord is claimed only when Noche's MenuTable binds it and the engine's table maps it to a different command:
//   Cmd+Shift+C      engine IDC_DEV_TOOLS_INSPECT, Noche Edit > Copy URL
//   Opt+Shift+Cmd+C  no row of its own, but an event with a lowercase "c" and Shift clears to the Cmd+Opt+C row (IDC_DEV_TOOLS_INSPECT); Noche Copy URL as Markdown
// A claimed chord never reaches the page: the monitor takes it ahead of the window and the renderer, so page JavaScript does not see it (not assertable in a hidden run, owner check 11; shortcuts-once asserts the claim counter).
// Everything else in the engine's table is either the same command as Noche's binding (Cmd+Opt+C Inspect, Cmd+Shift+[ and ], Cmd+1..9, Ctrl+Shift+PageDown and Up)
// or a chord Noche does not bind (left to the engine, listed in docs/app/README.md). Chrome's main-menu shortcuts are not engine accelerators here: Noche has its own menu.
- (BOOL)preemptKey:(NSEvent*)event {
  const NSEventModifierFlags m = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl);
  const NSEventModifierFlags cmd = NSEventModifierFlagCommand, shift = NSEventModifierFlagShift, opt = NSEventModifierFlagOption;
  static NSDictionary<NSString*, NSArray<NSNumber*>*>* table;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    table = @{@"c": @[@(shift | cmd), @(opt | shift | cmd)]};
  });
  NSString* key = event.charactersIgnoringModifiers.lowercaseString;
  if (NC_TEST_FLAG("NOCHE_TEST_NO_PREEMPT")) return NO;  // negative control: the engine's accelerators run first
  // Escape: Chromium enables IDC_CLOSE_FIND_OR_STOP only for its own find bar or a running load (browser_command_controller.cc:2726-2728), so on an idle page
  // it never reaches OnChromeCommand: Noche's find pill closes through this claim, which the delegate grants only while the pill shows.
  const BOOL escape = event.keyCode == 53 && m == 0;
  if (escape) {
    if (NC_TEST_FLAG("NOCHE_TEST_ESC_ALWAYS")) {  // negative control: Escape is claimed whatever the state
#ifdef NOCHE_TESTHOOKS
      g_preempted++;
#endif
      [self post:^(id<NCWindowDelegate> d) { [d window:self handlePreemptedKey:event]; }];
      return YES;
    }
    // Claimed only when the page's own view is the first responder (not a page dialog or another view), it has no IME composition (that Escape
    // belongs to the composition) and the tab is not in HTML fullscreen (Escape leaves it), and then only if the delegate agrees.
    NSView* page = self.webView ? FindByClass(self.webView, @"RenderWidgetHostViewCocoa") : nil;
    if (!page || self.nsWindow.firstResponder != page) return NO;
    if ([(id<NSTextInputClient>)page hasMarkedText]) return NO;
    if (self.activeTab.isHTMLFullscreen) return NO;
    id<NCWindowDelegate> d = _delegate;
    if (!d || ![d windowShouldClaimEscape:self]) return NO;
  } else if (![table[key] containsObject:@(m)]) {
    return NO;
  }
#ifdef NOCHE_TESTHOOKS
  g_preempted++;
#endif
  [self post:^(id<NCWindowDelegate> d) { [d window:self handlePreemptedKey:event]; }];
  return YES;
}

// Chromium handles these chords in its window's performKeyEquivalent before the renderer (no CEF key callback is made for them), so the claim is
// a local event monitor, which runs in NSApplication sendEvent ahead of the window. It only sees events of our own windows.
static NSHashTable<NCWindow*>* g_key_windows;
+ (void)registerForKeyClaims:(NCWindow*)w {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    g_key_windows = [NSHashTable weakObjectsHashTable];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* e) {
      for (NCWindow* c in g_key_windows) {
        if (e.window && e.window == c.nsWindow) return [c preemptKey:e] ? nil : e;
      }
      return e;
    }];
  });
  [g_key_windows addObject:w];
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
+ (void)testSetBeforeUnloadAnswer:(NSInteger)answer { g_unload_answer = answer; }
+ (NSInteger)testBeforeUnloadDialogs { return g_unload_dialogs; }

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
