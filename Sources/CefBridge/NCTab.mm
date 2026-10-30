#import "NCTabInternal.h"

#ifdef NOCHE_TESTHOOKS
NSInteger g_stop_find_calls = 0;  // read by NCWindow.testStopFindCalls
#endif
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
- (void)sendMethod:(NSString*)method params:(NSDictionary*)params sessionId:(NSString* _Nullable)sessionId timeout:(NSTimeInterval)timeout completion:(NCEvalCompletion)completion;
- (void)closeAfterDevTools:(int)left;
@end

@implementation NCTab {
  CefRefPtr<CefRegistration> _registration;
  NSMutableDictionary<NSNumber*, NCEvalCompletion>* _pending;
  NSMutableDictionary<NSString*, NSNumber*>* _childSessions;  // flat sessions of attached iframe targets (every session's, nested ones too)
  NSMutableSet<NSNumber*>* _wholeResult;                      // ids of |callDevToolsMethod:| calls: their reply is the whole |result|
  int _nextId;
  NSInteger _faviconGeneration;
  BOOL _waitingForDevTools;  // the 10 s of polling ran out with the DevTools still open
}

@synthesize identifier = _identifier, url = _url, title = _title, favicon = _favicon, faviconURL = _faviconURL;
@synthesize isDiscarded = _isDiscarded, isLoading = _isLoading, canGoBack = _canGoBack, canGoForward = _canGoForward;
@synthesize browser = _browser, closeRequested = _closeRequested;
@synthesize faviconListSeen = _faviconListSeen, clearFaviconAtLoadEnd = _clearFaviconAtLoadEnd, lastLoadURL = _lastLoadURL;

#ifdef NOCHE_TESTHOOKS
static BOOL g_force_html_fullscreen = NO;
+ (void)testForceHTMLFullscreen:(BOOL)on { g_force_html_fullscreen = on; }
#endif

- (BOOL)isHTMLFullscreen {
#ifdef NOCHE_TESTHOOKS
  if (g_force_html_fullscreen) return YES;
#endif
  return _browser && _browser->GetHost()->IsFullscreen();
}

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
    _childSessions = [NSMutableDictionary dictionary];
    _wholeResult = [NSMutableSet set];
  }
  return self;
}

- (double)zoomLevel {
  return _browser ? _browser->GetHost()->GetZoomLevel() : 0;
}

- (void)setZoomLevel:(double)zoomLevel {
  if (_browser) _browser->GetHost()->SetZoomLevel(zoomLevel);
}

- (void)zoomStep:(NSInteger)step {
  if (_browser) _browser->GetHost()->Zoom(step > 0 ? CEF_ZOOM_COMMAND_IN : step < 0 ? CEF_ZOOM_COMMAND_OUT : CEF_ZOOM_COMMAND_RESET);
}

- (void)loadURL:(NSString*)url {
  if (_browser && _browser->GetMainFrame()) _browser->GetMainFrame()->LoadURL(url.UTF8String);
}
- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
- (BOOL)discard { return _browser && _browser->GetHost()->DiscardTab(); }
- (void)reload { if (_browser) _browser->Reload(); }
- (void)reloadIgnoringCache { if (_browser) _browser->ReloadIgnoreCache(); }
- (void)stopLoad { if (_browser) _browser->StopLoad(); }

- (void)showDevTools {
  if (_browser) _browser->GetHost()->ShowDevTools(CefWindowInfo(), nullptr, CefBrowserSettings(), CefPoint());
}

// File > Print: Chromium's own print flow for this tab.
- (void)printPage {
  if (_browser) _browser->GetHost()->Print();
}

- (void)find:(NSString*)text forward:(BOOL)forward matchCase:(BOOL)matchCase findNext:(BOOL)next {
  if (_browser) _browser->GetHost()->Find(text.UTF8String, forward, matchCase, next);
}
- (void)stopFinding:(BOOL)clearSelection {
#ifdef NOCHE_TESTHOOKS
  g_stop_find_calls++;
#endif
  if (_browser) _browser->GetHost()->StopFinding(clearSelection);
}

// Runs the Chrome command with this IDC name on the tab when the engine says it can (Inspect Elements, JavaScript Console).
- (BOOL)executeChromeCommandNamed:(NSString*)name {
  if (!_browser) return NO;
  const int id = cef_id_for_command_id_name(name.UTF8String);
  if (id < 0 || !_browser->GetHost()->CanExecuteChromeCommand(id)) return NO;
  _browser->GetHost()->ExecuteChromeCommand(id, CEF_WOD_CURRENT_TAB);
  return YES;
}

- (BOOL)canExecuteChromeCommandNamed:(NSString*)name {
  if (!_browser) return NO;
  const int id = cef_id_for_command_id_name(name.UTF8String);
  return id >= 0 && _browser->GetHost()->CanExecuteChromeCommand(id);
}

#ifdef NOCHE_TESTHOOKS
- (BOOL)testExecuteChromeCommandNamed:(NSString*)name { return [self executeChromeCommandNamed:name]; }
#endif

#ifdef NOCHE_TESTHOOKS
- (void)testRightClickX:(double)x y:(double)y {
  for (NSString* type in @[ @"mouseMoved", @"mousePressed", @"mouseReleased" ]) {
    const BOOL moved = [type isEqualToString:@"mouseMoved"];
    NSDictionary* msg = @{
      @"id" : @(++_nextId),
      @"method" : @"Input.dispatchMouseEvent",
      @"params" : @{@"type" : type, @"x" : @(x), @"y" : @(y), @"button" : moved ? @"none" : @"right",
                    @"buttons" : [type isEqualToString:@"mousePressed"] ? @2 : @0, @"clickCount" : moved ? @0 : @1}
    };
    NSData* data = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self->_browser) self->_browser->GetHost()->SendDevToolsMessage(data.bytes, data.length);
    });
  }
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
  [self evaluateJavaScript:script sessionId:nil userGesture:YES timeout:0 completion:completion];
}

- (void)evaluateJavaScript:(NSString*)script
                 sessionId:(NSString*)sessionId
               userGesture:(BOOL)userGesture
                   timeout:(NSTimeInterval)timeout
                completion:(NCEvalCompletion)completion {
  [self sendMethod:@"Runtime.evaluate"
            params:@{@"expression" : script, @"returnByValue" : @YES, @"awaitPromise" : @YES, @"userGesture" : @(userGesture)}
         sessionId:sessionId
           timeout:timeout
        completion:completion];
}

- (void)attachChildTargets:(BOOL)on timeout:(NSTimeInterval)timeout completion:(void (^)(NSArray<NSString*>*, NSString* _Nullable))completion {
  [self sendMethod:@"Target.setAutoAttach"
            params:@{@"autoAttach" : @(on), @"waitForDebuggerOnStart" : @NO, @"flatten" : @YES}
         sessionId:nil
           timeout:timeout
        completion:^(NSString* json, NSString* error) { completion(error ? @[] : [self->_childSessions allKeys], error); }];
}

- (NSArray<NSString*>*)childSessionIds { return [_childSessions allKeys]; }

- (void)callDevToolsMethod:(NSString*)method
                paramsJSON:(NSString*)paramsJSON
                 sessionId:(NSString*)sessionId
                   timeout:(NSTimeInterval)timeout
                completion:(NCEvalCompletion)completion {
  id params = [NSJSONSerialization JSONObjectWithData:[paramsJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  if (![params isKindOfClass:NSDictionary.class]) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"bad params"); });
    return;
  }
  const int rid = _nextId + 1;  // the id |sendMethod:| is about to use
  [_wholeResult addObject:@(rid)];
  [self sendMethod:method params:params sessionId:sessionId timeout:timeout completion:completion];
}

// One CDP command, with its completion run exactly once: by the reply, by |timeout| seconds (0: none) with nil and "timed out" (the entry is
// removed, so a late reply finds none and is dropped), or by the tab closing.
- (void)sendMethod:(NSString*)method
            params:(NSDictionary*)params
         sessionId:(NSString*)sessionId
           timeout:(NSTimeInterval)timeout
        completion:(NCEvalCompletion)completion {
  if (!_browser) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"tab closed"); });
    return;
  }
  const int rid = ++_nextId;
  NSMutableDictionary* msg = [@{@"id" : @(rid), @"method" : method, @"params" : params} mutableCopy];
  if (sessionId) msg[@"sessionId"] = sessionId;
  NSData* data = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
  _pending[@(rid)] = [completion copy];
  // Posted: a send from inside a reply callback is dispatched synchronously and iterates the DevTools observer
  // list again, which CHECKs in Chromium (found by the engine probe).
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_browser) self->_browser->GetHost()->SendDevToolsMessage(data.bytes, data.length);
  });
#ifdef NOCHE_TESTHOOKS
  if (NC_TEST_FLAG("NOCHE_TEST_DISCARD_NOTIMEOUT")) return;  // negative control: no timeout
#endif
  if (timeout > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NCEvalCompletion cb = self->_pending[@(rid)];
      if (!cb) return;
      [self->_pending removeObjectForKey:@(rid)];
      [self->_wholeResult removeObject:@(rid)];
      cb(nil, @"timed out");
    });
  }
}

- (BOOL)handleDevToolsMessage:(NSData*)data {
  NSDictionary* j = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![j isKindOfClass:NSDictionary.class]) return NO;
  if (NSString* event = j[@"method"]) {  // the child targets (cross-origin frames) attached by |attachChildTargets:|
    NSDictionary* p = j[@"params"];
    if ([event isEqualToString:@"Target.attachedToTarget"] && p[@"sessionId"] && [p[@"targetInfo"][@"type"] isEqualToString:@"iframe"]) _childSessions[p[@"sessionId"]] = @YES;
    if ([event isEqualToString:@"Target.detachedFromTarget"] && p[@"sessionId"]) [_childSessions removeObjectForKey:p[@"sessionId"]];
    return NO;
  }
  if (!j[@"id"]) return NO;
  NSNumber* key = @([j[@"id"] intValue]);
  NCEvalCompletion cb = _pending[key];
  if (!cb) return NO;
  [_pending removeObjectForKey:key];
  const BOOL whole = [_wholeResult containsObject:key];
  [_wholeResult removeObject:key];
  // Completions never run inside the CEF callback that carries the reply.
  void (^done)(NSString*, NSString*) = ^(NSString* json, NSString* error) {
    dispatch_async(dispatch_get_main_queue(), ^{ cb(json, error); });
  };
  if (NSDictionary* err = j[@"error"]) {
    done(nil, [err isKindOfClass:NSDictionary.class] ? (err[@"message"] ?: @"CDP error") : @"CDP error");
    return YES;
  }
  NSDictionary* result = j[@"result"];
  if (whole) {
    NSData* all = [NSJSONSerialization dataWithJSONObject:(result ?: @{}) options:0 error:nil];
    done(all ? [[NSString alloc] initWithData:all encoding:NSUTF8StringEncoding] : @"{}", nil);
    return YES;
  }
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
  [_wholeResult removeAllObjects];
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
