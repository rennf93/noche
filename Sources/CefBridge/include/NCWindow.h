#import <AppKit/AppKit.h>

#ifndef NC_EXPORT
#define NC_EXPORT __attribute__((visibility("default")))
#endif

NS_ASSUME_NONNULL_BEGIN

@class NCWindow, NCTab;

typedef NS_ENUM(NSInteger, NCWindowMode) { NCWindowModeNormal, NCWindowModeHidden };

/// Every callback arrives on the main thread, from a task posted after the CEF callback that caused it.
NS_SWIFT_UI_ACTOR
@protocol NCWindowDelegate <NSObject>
- (void)window:(NCWindow *)window didAddTab:(NCTab *)tab active:(BOOL)active;          // every tab, the first included
- (void)window:(NCWindow *)window didActivateTab:(NCTab *)tab previous:(nullable NCTab *)previous;
- (void)window:(NCWindow *)window didCloseTab:(NCTab *)tab;
- (void)window:(NCWindow *)window didUpdateTab:(NCTab *)tab;                            // title, url, loading, back/forward, favicon
- (void)window:(NCWindow *)window tab:(NCTab *)tab didFinishLoadWithStatus:(NSInteger)status;
- (void)window:(NCWindow *)window tab:(NCTab *)tab didFailLoadWithCode:(NSInteger)code url:(NSString *)failedURL;  // not for ERR_ABORTED
/// Called synchronously inside CEF's command handler. YES: Noche handled it, CEF must not.
- (BOOL)window:(NCWindow *)window shouldHandleChromeCommand:(NSInteger)commandId;
- (void)windowDidClose:(NCWindow *)window;
@end

NC_EXPORT NS_SWIFT_UI_ACTOR
@interface NCWindow : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithURL:(NSString *)url frame:(NSRect)frame mode:(NCWindowMode)mode delegate:(id<NCWindowDelegate>)delegate NS_DESIGNATED_INITIALIZER;
@property(nonatomic, readonly, nullable) NSWindow *nsWindow;     // nil until the CefWindow exists
@property(nonatomic, readonly, nullable) NSView *chromeHost;     // theme frame; AppKit chrome goes here above the content view
/// Web view rect inside the window (top, left, bottom, right), window points. Applied as the window box layout's inside border;
/// setting it again re-applies the layout.
@property(nonatomic) NSEdgeInsets webInsets;
@property(nonatomic) CGFloat webCornerRadius;                     // bottom corners of the web view mask (0: no mask), re-applied on every bounds change
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
/// Test support: YES while a CEF handler of the bridge is on the stack.
+ (BOOL)insideCefCallback;
/// Test support: DevTools browsers created, whose front end finished loading, and that ended (OnBeforeClose), all windows.
+ (NSInteger)devToolsCreated;
+ (NSInteger)devToolsLoaded;
+ (NSInteger)devToolsClosed;
/// Attempts to set alpha above 0 (clamped to 0), on windows of NCWindow and on any other window.
+ (NSInteger)alphaAttemptsOnOwnWindows;
+ (NSInteger)alphaAttemptsOnOtherWindows;

/// The view that shows the page (WebContentsViewCocoa), nil until it exists.
@property(nonatomic, readonly, nullable) NSView *webView;
/// Test support for the corner mask: YES when a mask exists; whether a point (window base coordinates, origin bottom-left) is inside it.
@property(nonatomic, readonly) BOOL webMaskExists;
- (BOOL)webMaskContainsWindowPoint:(NSPoint)point;
@end

NC_EXPORT NS_SWIFT_UI_ACTOR
@interface NCTab : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSInteger identifier;             // CefBrowser::GetIdentifier
@property(nonatomic, readonly, copy) NSString *url;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly) BOOL isLoading, canGoBack, canGoForward;
@property(nonatomic, readonly, nullable) NSImage *favicon;
@property(nonatomic) double zoomLevel;
- (void)loadURL:(NSString *)url;
- (void)goBack; - (void)goForward; - (void)reload; - (void)reloadIgnoringCache; - (void)stopLoad;
- (void)showDevTools;
- (void)close;
/// CDP Runtime.evaluate (awaitPromise, returnByValue). |json| is the JSON of the result value, |error| the exception or CDP error.
- (void)evaluateJavaScript:(NSString *)script completion:(void (^)(NSString *_Nullable json, NSString *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
