#pragma once
#import "CefBridge.h"
#include "include/cef_browser.h"

// Bridge-private side of NCTab: NCWindow.mm mutates the state, the public header only reads it.
NS_ASSUME_NONNULL_BEGIN

// Test switches and the callback depth counter exist only in builds with NOCHE_TESTHOOKS; elsewhere the names are not even in the binary.
#ifdef NOCHE_TESTHOOKS
/// Depth of CEF handler calls in progress on the UI thread (test support: +[NCWindow insideCefCallback]).
inline int g_nc_cef_depth = 0;
struct NCCefScope {
  NCCefScope() { g_nc_cef_depth++; }
  ~NCCefScope() { g_nc_cef_depth--; }
};
#define NC_CEF_CALLBACK NCCefScope nc_cef_scope_
inline bool NCTestFlag(const char* name) {
  const char* v = getenv(name);
  return v && v[0] == '1';
}
#define NC_TEST_FLAG(name) NCTestFlag(name)
/// An integer switch (milliseconds, counts); 0 when unset.
inline int NCTestInt(const char* name) {
  const char* v = getenv(name);
  return v ? atoi(v) : 0;
}
#else
#define NC_CEF_CALLBACK ((void)0)
#define NC_TEST_FLAG(name) false
#endif

@interface NCTab ()
@property(nonatomic, readwrite) NSInteger identifier;
@property(nonatomic, readwrite, copy) NSString* url;
@property(nonatomic, readwrite, copy) NSString* title;
@property(nonatomic, readwrite) BOOL isLoading, canGoBack, canGoForward;
@property(nonatomic, readwrite) BOOL isHTMLFullscreen;
@property(nonatomic, readwrite, nullable) NSImage* favicon;
@property(nonatomic, readwrite, copy, nullable) NSString* faviconURL;
/// YES from [close] until the tab ends or the close is reported cancelled (a beforeunload dialog answered Stay).
@property(nonatomic) BOOL closeRequested;
/// Favicon bookkeeping for the current main-frame load: Chrome sends no icon list for a page without icons, so a load that ended
/// with none has to clear the previous page's icon itself.
@property(nonatomic) BOOL faviconListSeen, clearFaviconAtLoadEnd;
@property(nonatomic, copy, nullable) NSString* lastLoadURL;
/// Null once the browser is closed.
@property(nonatomic) CefRefPtr<CefBrowser> browser;
+ (instancetype)tabWithBrowser:(CefRefPtr<CefBrowser>)browser;
/// Forgets the favicon, and drops a download still in flight so it cannot bring the old one back.
- (void)clearFavicon;
/// A DevTools browser of this window ended: a close that stopped polling for it tries again.
- (void)devToolsEnded;
/// Drops the browser and the DevTools observer and fails every pending evaluation.
- (void)browserClosed;
/// Downloads the favicon at |url| (36 px) and calls |done| on the UI thread when it was set.
- (void)loadFaviconFromURL:(NSString*)url done:(void (^)(void))done;
@end

NS_ASSUME_NONNULL_END
