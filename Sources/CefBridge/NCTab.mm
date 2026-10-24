#import "NCTabInternal.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_image.h"

namespace {

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
  NCFaviconCallback(NCTab* tab, void (^done)(void)) : tab_(tab), done_(done) {}
  void OnDownloadImageFinished(const CefString&, int, CefRefPtr<CefImage> image) override {
    NC_CEF_CALLBACK;
    NCTab* tab = tab_;
    if (!tab || !image) return;
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
}

@synthesize identifier = _identifier, url = _url, title = _title, favicon = _favicon;
@synthesize isLoading = _isLoading, canGoBack = _canGoBack, canGoForward = _canGoForward;
@synthesize browser = _browser;

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

- (void)close {
  if (!_browser) return;
  CefRefPtr<CefBrowserHost> host = _browser->GetHost();
  // The DevTools browser of a closing tab goes first (closing the tab under it can leave it alive until the profile dies).
  if (host->HasDevTools()) {
    host->CloseDevTools();
    [self closeAfterDevTools:40];
  } else {
    host->CloseBrowser(false);
  }
}

- (void)closeAfterDevTools:(int)left {
  if (!_browser) return;
  if (left > 0 && _browser->GetHost()->HasDevTools()) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 20), dispatch_get_main_queue(), ^{ [self closeAfterDevTools:left - 1]; });
    return;
  }
  _browser->GetHost()->CloseBrowser(false);
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

- (void)loadFaviconFromURL:(NSString*)url done:(void (^)(void))done {
  if (_browser) _browser->GetHost()->DownloadImage(url.UTF8String, true, 36, false, new NCFaviconCallback(self, done));
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
