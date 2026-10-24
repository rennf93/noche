#import "NCTabInternal.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_id_mappers.h"
#include "include/cef_image.h"

@interface NCTab (Favicon)
- (BOOL)faviconGenerationIs:(NSInteger)generation;
@end

namespace {

bool NCFaviconIsCurrent(NCTab* tab, NSInteger generation) { return [tab faviconGenerationIs:generation]; }

class NCDevToolsObserver : public CefDevToolsMessageObserver {
 public:
  explicit NCDevToolsObserver(NCTab* tab) : tab_(tab) {}
  bool OnDevToolsMessage(CefRefPtr<CefBrowser>, const void* message, size_t size) override;

 private:
  __weak NCTab* tab_;
  IMPLEMENT_REFCOUNTING(NCDevToolsObserver);
};

class NCFaviconCallback : public CefDownloadImageCallback {
 public:
  NCFaviconCallback(NCTab* tab, NSInteger generation, void (^done)(void)) : tab_(tab), generation_(generation), done_(done) {}
  void OnDownloadImageFinished(const CefString&, int, CefRefPtr<CefImage> image) override {
    NC_CEF_CALLBACK;
    NCTab* tab = tab_;
    if (!tab || !image || !NCFaviconIsCurrent(tab, generation_)) return;  // cleared or replaced while it downloaded
    int w = 0, h = 0;
    CefRefPtr<CefBinaryValue> png = image->GetAsPNG(1.0f, true, w, h);
    if (!png || !png->GetSize()) return;
    NSMutableData* data = [NSMutableData dataWithLength:png->GetSize()];
    png->GetData(data.mutableBytes, data.length, 0);
    NSImage* img = [[NSImage alloc] initWithData:data];
    if (!img) return;
    tab.favicon = img;
    if (done_) done_();
  }

 private:
  __weak NCTab* tab_;
  NSInteger generation_;
  void (^done_)(void);
  IMPLEMENT_REFCOUNTING(NCFaviconCallback);
};

}  // namespace

typedef void (^NCEvalCompletion)(NSString* _Nullable json, NSString* _Nullable error);

@interface NCTab ()
- (instancetype)initPrivate;
- (BOOL)handleDevToolsMessage:(NSData*)data;
- (void)closeAfterDevTools:(int)left;
@end

@implementation NCTab {
  CefRefPtr<CefRegistration> _registration;
  NSMutableDictionary<NSNumber*, NCEvalCompletion>* _pending;
  int _nextId;
  NSInteger _faviconGeneration;
  BOOL _waitingForDevTools;  // the 10 s of polling ran out with the DevTools still open
}

@synthesize identifier = _identifier, url = _url, title = _title, favicon = _favicon, faviconURL = _faviconURL;
@synthesize isLoading = _isLoading, canGoBack = _canGoBack, canGoForward = _canGoForward;
@synthesize browser = _browser, closeRequested = _closeRequested;
@synthesize faviconListSeen = _faviconListSeen, clearFaviconAtLoadEnd = _clearFaviconAtLoadEnd, lastLoadURL = _lastLoadURL;

+ (instancetype)tabWithBrowser:(CefRefPtr<CefBrowser>)browser {
  NCTab* tab = [[NCTab alloc] initPrivate];
  tab->_browser = browser;
  tab->_identifier = browser->GetIdentifier();
  tab->_url = browser->GetMainFrame() ? @(browser->GetMainFrame()->GetURL().ToString().c_str()) : @"";
  tab->_registration = browser->GetHost()->AddDevToolsMessageObserver(new NCDevToolsObserver(tab));
  return tab;
}

- (instancetype)initPrivate {
  if ((self = [super init])) {
    _url = @"";
    _title = @"";
    _pending = [NSMutableDictionary dictionary];
  }
  return self;
}

- (double)zoomLevel {
  return _browser ? _browser->GetHost()->GetZoomLevel() : 0;
}

- (void)setZoomLevel:(double)zoomLevel {
  if (_browser) _browser->GetHost()->SetZoomLevel(zoomLevel);
}

- (void)loadURL:(NSString*)url {
  if (_browser && _browser->GetMainFrame()) _browser->GetMainFrame()->LoadURL(url.UTF8String);
}
- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
- (void)reload { if (_browser) _browser->Reload(); }
- (void)reloadIgnoringCache { if (_browser) _browser->ReloadIgnoreCache(); }
- (void)stopLoad { if (_browser) _browser->StopLoad(); }

- (void)showDevTools {
  if (_browser) _browser->GetHost()->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint());
}

#ifdef NOCHE_TESTHOOKS
- (BOOL)testExecuteChromeCommandNamed:(NSString*)name {
  if (!_browser) return NO;
  const int id = cef_id_for_command_id_name(name.UTF8String);
  if (id < 0 || !_browser->GetHost()->CanExecuteChromeCommand(id)) return NO;
  _browser->GetHost()->ExecuteChromeCommand(id, CEF_WOD_CURRENT_TAB);
  return YES;
}
#endif

- (void)close {
  if (!_browser) return;
  _closeRequested = YES;
  CefRefPtr<CefBrowserHost> host = _browser->GetHost();
  // The DevTools browser of a closing tab goes first (closing the tab under it can leave it alive until the profile dies).
  // Negative control: the tab closes under its DevTools.
  if (host->HasDevTools() && !NC_TEST_FLAG("NOCHE_TEST_DEVTOOLS_LAST")) {
    host->CloseDevTools();
    [self closeAfterDevTools:200];
  } else {
    host->CloseBrowser(false);
  }
}

// Polls every 50 ms for up to 10 s (|left| counts the polls). The tab never closes under its DevTools: past 10 s polling stops
// with a NOCHE line and the close waits for the window's report that a DevTools browser ended (-devToolsEnded); the app's quit
// watchdog bounds a quit that waits longer.
- (void)closeAfterDevTools:(int)left {
  if (!_browser) return;
  if (_browser->GetHost()->HasDevTools()) {
    if (left == 160) fprintf(stderr, "NOCHE devtools still open after 2 s, tab not closed early\n");  // the checks fail on this line
    if (left == 0) {
      fprintf(stderr, "NOCHE devtools still open after 10 s, tab close waits for the DevTools to end\n");
      _waitingForDevTools = YES;
      return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 20), dispatch_get_main_queue(), ^{ [self closeAfterDevTools:left - 1]; });
    return;
  }
  _waitingForDevTools = NO;
  _browser->GetHost()->CloseBrowser(false);
}

- (void)devToolsEnded {
  if (_waitingForDevTools) [self closeAfterDevTools:200];
}

- (void)evaluateJavaScript:(NSString*)script completion:(NCEvalCompletion)completion {
  if (!_browser) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"tab closed"); });
    return;
  }
  const int rid = ++_nextId;
  NSDictionary* msg = @{
    @"id" : @(rid),
    @"method" : @"Runtime.evaluate",
    @"params" : @{@"expression" : script, @"returnByValue" : @YES, @"awaitPromise" : @YES, @"userGesture" : @YES}
  };
  NSData* data = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
  _pending[@(rid)] = [completion copy];
  // Posted: a send from inside a reply callback is dispatched synchronously and iterates the DevTools observer
  // list again, which CHECKs in Chromium (found by the engine probe).
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_browser) self->_browser->GetHost()->SendDevToolsMessage(data.bytes, data.length);
  });
}

- (BOOL)handleDevToolsMessage:(NSData*)data {
  NSDictionary* j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![j isKindOfClass:NSDictionary.class] || !j[@"id"]) return NO;
  NSNumber* key = @([j[@"id"] intValue]);
  NCEvalCompletion cb = _pending[key];
  if (!cb) return NO;
  [_pending removeObjectForKey:key];
  // Completions never run inside the CEF callback that carries the reply.
  void (^done)(NSString*, NSString*) = ^(NSString* json, NSString* error) {
    dispatch_async(dispatch_get_main_queue(), ^{ cb(json, error); });
  };
  if (NSDictionary* err = j[@"error"]) {
    done(nil, [err isKindOfClass:NSDictionary.class] ? (err[@"message"] ?: @"CDP error") : @"CDP error");
    return YES;
  }
  NSDictionary* result = j[@"result"];
  if (NSDictionary* ex = result[@"exceptionDetails"]) {
    done(nil, ex[@"exception"][@"description"] ?: ex[@"text"] ?: @"exception");
    return YES;
  }
  id value = result[@"result"][@"value"];
  if (!value) {  // undefined
    done(@"null", nil);
    return YES;
  }
  NSData* out = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
  done(out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] : @"null", nil);
  return YES;
}

- (void)browserClosed {
  _registration = nullptr;
  _browser = nullptr;
  NSArray<NCEvalCompletion>* callbacks = _pending.allValues;
  [_pending removeAllObjects];
  for (NCEvalCompletion cb in callbacks) dispatch_async(dispatch_get_main_queue(), ^{ cb(nil, @"tab closed"); });
}

- (BOOL)faviconGenerationIs:(NSInteger)generation { return generation == _faviconGeneration; }

- (void)clearFavicon {
  _faviconGeneration++;
  _favicon = nil;
  _faviconURL = nil;
}

- (void)loadFaviconFromURL:(NSString*)url done:(void (^)(void))done {
  const NSInteger generation = ++_faviconGeneration;
  void (^guarded)(void) = ^{ if (generation == self->_faviconGeneration) done(); };
  if (_browser) _browser->GetHost()->DownloadImage(url.UTF8String, true, 36, false, new NCFaviconCallback(self, generation, guarded));
}

@end

namespace {

bool NCDevToolsObserver::OnDevToolsMessage(CefRefPtr<CefBrowser>, const void* message, size_t size) {
  NC_CEF_CALLBACK;
  NCTab* tab = tab_;
  if (!tab) return false;
  return [tab handleDevToolsMessage:[NSData dataWithBytes:message length:size]];
}

}  // namespace
