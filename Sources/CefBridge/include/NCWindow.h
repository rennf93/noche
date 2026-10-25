#import <AppKit/AppKit.h>

#ifndef NC_EXPORT
#define NC_EXPORT __attribute__((visibility("default")))
#endif

NS_ASSUME_NONNULL_BEGIN

@class NCWindow, NCTab;

typedef NS_ENUM(NSInteger, NCMenuItemType) { NCMenuItemTypeCommand, NCMenuItemTypeCheck, NCMenuItemTypeRadio, NCMenuItemTypeSeparator, NCMenuItemTypeSubmenu };

/// One row of Chromium's context menu model, copied while the engine's model is alive (it must not be kept). Labels are Chromium's own,
/// with the `&` mnemonic markers removed.
NC_EXPORT
@interface NCMenuItem : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSInteger commandId;
@property(nonatomic, readonly, copy) NSString *label;
@property(nonatomic, readonly) NCMenuItemType type;
@property(nonatomic, readonly) BOOL enabled, visible, checked;
@property(nonatomic, readonly, nullable) NSArray<NCMenuItem *> *submenu;   // type Submenu only
@end

typedef NS_ENUM(NSInteger, NCWindowMode) { NCWindowModeNormal, NCWindowModeHidden };

/// Every callback arrives on the main thread, from a task posted after the CEF callback that caused it.
NS_SWIFT_UI_ACTOR
@protocol NCWindowDelegate <NSObject>
- (void)window:(NCWindow *)window didAddTab:(NCTab *)tab active:(BOOL)active;          // every tab, the first included
- (void)window:(NCWindow *)window didActivateTab:(NCTab *)tab previous:(nullable NCTab *)previous;
- (void)window:(NCWindow *)window didCloseTab:(NCTab *)tab;
/// A close the host asked for ([NCTab close]) did not happen: the page's beforeunload dialog was answered "Stay".
- (void)window:(NCWindow *)window didCancelCloseOfTab:(NCTab *)tab;
- (void)window:(NCWindow *)window didUpdateTab:(NCTab *)tab;                            // title, url, loading, back/forward, favicon
- (void)window:(NCWindow *)window tab:(NCTab *)tab didFinishLoadWithStatus:(NSInteger)status;
- (void)window:(NCWindow *)window tab:(NCTab *)tab didFailLoadWithCode:(NSInteger)code url:(NSString *)failedURL;  // not for ERR_ABORTED
/// Called synchronously inside CEF's command handler. YES: Noche handled it, CEF must not.
- (BOOL)window:(NCWindow *)window shouldHandleChromeCommand:(NSInteger)commandId;
- (void)windowDidClose:(NCWindow *)window;
/// A key the engine would take as its own accelerator, which Noche owns instead. The page never sees it: the monitor takes it ahead of the window and the renderer.
/// Delivered on a later main-queue turn; the bridge has already told the engine the key is handled.
- (void)window:(NCWindow *)window handlePreemptedKey:(NSEvent *)event;
/// The page's context menu: |items| is a copy of Chromium's model, |point| the click in window base coordinates. The host shows its own
/// menu and calls |completion| exactly once, on the main queue, with the chosen command id (Chromium runs it) or -1 (the menu was dismissed).
- (void)window:(NCWindow *)window tab:(NCTab *)tab showContextMenu:(NSArray<NCMenuItem *> *)items atWindowPoint:(NSPoint)point completion:(void (^)(NSInteger commandId))completion;
@end

NC_EXPORT NS_SWIFT_UI_ACTOR
@interface NCWindow : NSObject
- (instancetype)init NS_UNAVAILABLE;
/// |frame| is the window's frame in AppKit global coordinates (origin bottom-left of the primary screen, y up, the space of
/// NSWindow.frame); the bridge converts to CEF's top-left DIPs. macOS may still move a window that starts inside the Stage Manager strip.
- (instancetype)initWithURL:(NSString *)url frame:(NSRect)frame mode:(NCWindowMode)mode delegate:(id<NCWindowDelegate>)delegate NS_DESIGNATED_INITIALIZER;
@property(nonatomic, readonly, nullable) NSWindow *nsWindow;     // nil until the CefWindow exists
@property(nonatomic, readonly, nullable) NSView *chromeHost;     // theme frame; AppKit chrome goes here above the content view
/// Web view rect inside the window (top, left, bottom, right), window points. Applied as the window box layout's inside border;
/// setting it again re-applies the layout.
@property(nonatomic) NSEdgeInsets webInsets;
@property(nonatomic) CGFloat webCornerRadius;                     // bottom corners of the web view mask (0: no mask), re-applied on every bounds change
/// YES hides the page view (the tab stays alive and its renderer keeps running) so what is behind the web rect shows through;
/// NO shows it again at the same insets and mask. Window-wide, and reset by the bridge: any switch of the active tab
/// (activateTab:, addTabWithURL:activate:YES, an engine-initiated change) sets it back to NO first, so the caller sets it
/// again for a tab that wants to stay hidden.
@property(nonatomic) BOOL webContentHidden;
/// Gives keyboard focus back to the active tab's page (after an AppKit view held it).
- (void)focusActiveContent;
@property(nonatomic, readonly) NSArray<NCTab *> *tabs;           // tab strip order
@property(nonatomic, readonly, nullable) NCTab *activeTab;
@property(nonatomic, readonly) NSInteger devToolsCount;          // DevTools browsers open for this window's tabs
- (nullable NCTab *)addTabWithURL:(NSString *)url activate:(BOOL)activate;
- (void)activateTab:(NCTab *)tab;
- (void)close;                                                    // closes every tab, then the window

/// Hidden-mode guards (process wide, call once before CefInitialize): window alpha is clamped to 0 and mouse events
/// ignored whoever orders a window in, and every NSApplication/NSRunningApplication activation call becomes a counted no-op.
+ (void)installHiddenGuards;
+ (NSInteger)activationsBlocked;
#ifdef NOCHE_TESTHOOKS
/// Test support (builds with NOCHE_TESTHOOKS only): YES while a CEF handler of the bridge is on the stack.
+ (BOOL)insideCefCallback;
/// Test support: DevTools browsers created, whose front end finished loading, and that ended (OnBeforeClose), all windows.
+ (NSInteger)devToolsCreated;
+ (NSInteger)devToolsLoaded;
+ (NSInteger)devToolsClosed;
/// Test support: keys the bridge claimed before the engine's accelerators (`preemptKey:`), all windows.
+ (NSInteger)testPreemptedKeys;
#endif
#ifdef NOCHE_TESTHOOKS
/// Test support: how the beforeunload dialog is answered (0: Chrome's own dialog, 1: Stay, 2: Leave), and how many were asked.
+ (void)testSetBeforeUnloadAnswer:(NSInteger)answer;
+ (NSInteger)testBeforeUnloadDialogs;
#endif
/// Attempts to set alpha above 0 (clamped to 0), on windows of NCWindow and on any other window.
+ (NSInteger)alphaAttemptsOnOwnWindows;
+ (NSInteger)alphaAttemptsOnOtherWindows;

/// The view that shows the page (WebContentsViewCocoa): nil until it exists, while hidden, and when more than one is visible (not guessable).
@property(nonatomic, readonly, nullable) NSView *webView;
/// Test support for the corner mask: YES when a mask exists; whether a point (window base coordinates, origin bottom-left) is inside it.
@property(nonatomic, readonly) BOOL webMaskExists;
- (BOOL)webMaskContainsWindowPoint:(NSPoint)point;
#ifdef NOCHE_TESTHOOKS
/// Test support: how many times the window layout was rebuilt and the corner mask path recomputed.
@property(nonatomic, readonly) NSInteger testLayoutPasses, testMaskPasses;
/// Test support: focusActiveContent calls that found more than one page view and left the responder alone (NOCHE_TEST_PAGE_VIEWS=N makes the count read N).
@property(nonatomic, readonly) NSInteger testAmbiguousFocusLogs;
#endif
@end

NC_EXPORT NS_SWIFT_UI_ACTOR
@interface NCTab : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSInteger identifier;             // CefBrowser::GetIdentifier
@property(nonatomic, readonly, copy) NSString *url;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly) BOOL isLoading, canGoBack, canGoForward;
@property(nonatomic, readonly, nullable) NSImage *favicon;
/// The address of the icon Chrome reported for the page (the first of its list), nil when the page has none.
@property(nonatomic, readonly, copy, nullable) NSString *faviconURL;
@property(nonatomic) double zoomLevel;
- (void)loadURL:(NSString *)url;
- (void)goBack; - (void)goForward; - (void)reload; - (void)reloadIgnoringCache; - (void)stopLoad;
- (void)showDevTools;
- (void)printPage;
/// Runs the Chrome command with this IDC name on the tab when the engine can execute it; NO when it cannot.
- (BOOL)executeChromeCommandNamed:(NSString *)name;
/// Whether the engine says it can execute the Chrome command with this IDC name on the tab right now.
- (BOOL)canExecuteChromeCommandNamed:(NSString *)name;
#ifdef NOCHE_TESTHOOKS
/// Test support (builds with NOCHE_TESTHOOKS only): runs the Chrome command with this IDC name on the tab, bypassing Noche's actions.
- (BOOL)testExecuteChromeCommandNamed:(NSString *)name;
#endif
- (void)close;
#ifdef NOCHE_TESTHOOKS
/// Test support: a right click at (x, y) of the page (CSS pixels) through DevTools input, the way a person's click reaches the renderer.
- (void)testRightClickX:(double)x y:(double)y;
#endif
/// CDP Runtime.evaluate (awaitPromise, returnByValue). |json| is the JSON of the result value, |error| the exception or CDP error.
- (void)evaluateJavaScript:(NSString *)script completion:(void (^)(NSString *_Nullable json, NSString *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
