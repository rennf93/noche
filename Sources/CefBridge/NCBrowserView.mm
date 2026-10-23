#import "CefBridge.h"
#include "include/cef_client.h"
#include "include/cef_browser.h"

@class NCBrowserView;

namespace {

class NCClient : public CefClient, public CefLoadHandler, public CefDisplayHandler, public CefLifeSpanHandler {
 public:
  explicit NCClient(NCBrowserView* view) : view_(view) {}

  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int status) override;
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString&,
                   const CefString&) override;
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { browser_ = browser; }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override;

  CefRefPtr<CefBrowser> browser() const { return browser_; }

 private:
  // Strong until OnBeforeClose: the window can release the view before CEF finishes closing.
  NCBrowserView* view_;
  CefRefPtr<CefBrowser> browser_;
  IMPLEMENT_REFCOUNTING(NCClient);
};

}  // namespace

@implementation NCBrowserView {
  NSString* _url;
  CefRefPtr<NCClient> _client;
  BOOL _created;
}

- (instancetype)initWithFrame:(NSRect)frame url:(NSString*)url {
  if ((self = [super initWithFrame:frame])) {
    _url = [url copy];
    self.autoresizesSubviews = YES;
  }
  return self;
}

// The child view needs a window, so the browser is created on first attach.
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (_created || !self.window) return;
  _created = YES;
  _client = new NCClient(self);
  NSRect b = self.bounds;
  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)self, CefRect(0, 0, (int)b.size.width, (int)b.size.height));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  if (!CefBrowserHost::CreateBrowserSync(info, _client, _url.UTF8String, CefBrowserSettings(), nullptr, nullptr)) {
    NSLog(@"NOCHE CreateBrowserSync failed for %@", _url);
  }
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
  [super resizeSubviewsWithOldSize:oldSize];
  if (_client && _client->browser()) {
    NSView* child = (__bridge NSView*)_client->browser()->GetHost()->GetWindowHandle();
    child.frame = self.bounds;
  }
}

- (void)close {
  if (_client && _client->browser()) {
    _client->browser()->GetHost()->CloseBrowser(false);
  } else if (auto cb = self.onClosed) {  // no browser (creation failed or never attached): nothing to wait for
    self.onClosed = nil;
    cb();
  }
}

@end

namespace {

void NCClient::OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int status) {
  if (!frame->IsMain()) return;
  if (auto cb = view_.onLoadEnd) cb(status);
}

void NCClient::OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString&,
                           const CefString&) {
  if (!frame->IsMain() || code == ERR_ABORTED) return;
  if (auto cb = view_.onLoadError) cb(code);
}

void NCClient::OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) {
  if (auto cb = view_.onTitleChange) cb(@(title.ToString().c_str()));
}

void NCClient::OnBeforeClose(CefRefPtr<CefBrowser>) {
  browser_ = nullptr;
  NCBrowserView* v = view_;
  view_ = nil;
  if (auto cb = v.onClosed) cb();
}

}  // namespace
