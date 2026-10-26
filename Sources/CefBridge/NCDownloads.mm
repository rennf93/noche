#import "CefBridge.h"
#import "NCTabInternal.h"
#include <map>
#include "NCInternal.h"
#include "include/cef_download_handler.h"
#include "include/cef_request_context.h"

@interface NCDownloadItem ()
- (instancetype)initPrivate;
@property(nonatomic, readwrite) uint32_t identifier;
@property(nonatomic, readwrite, copy) NSString *url, *suggestedName, *fullPath;
@property(nonatomic, readwrite) int64_t receivedBytes, totalBytes, speed;
@property(nonatomic, readwrite) NSInteger percent;
@property(nonatomic, readwrite) NCDownloadState state;
@end

@implementation NCDownloadItem
- (instancetype)initPrivate { return [super init]; }
@end

@interface NCDownloads ()
- (instancetype)initPrivate;
- (void)willDownload:(uint32_t)identifier name:(NSString*)name;
- (void)updated:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback;
@end

namespace {

NSString* Str(const CefString& s) { return @(s.ToString().c_str()); }

// The one handler: the window clients return it for downloads that have a tab, and the global request context for the ones without.
class NCDownloadHandler : public CefDownloadHandler {
 public:
  // The default handling stays: Chromium's target determiner picks the file name and folder (download.default_directory). Only the name is noted.
  bool OnBeforeDownload(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, const CefString& suggested_name, CefRefPtr<CefBeforeDownloadCallback>) override {
    NC_CEF_CALLBACK;
    [NCDownloads.shared willDownload:item->GetId() name:Str(suggested_name)];
    return false;
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser>, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback> callback) override {
    NC_CEF_CALLBACK;
    [NCDownloads.shared updated:item callback:callback];
  }

 private:
  IMPLEMENT_REFCOUNTING(NCDownloadHandler);
};

}  // namespace

CefRefPtr<CefDownloadHandler> NCDownloadHandlerInstance() {
  static CefRefPtr<CefDownloadHandler> handler = new NCDownloadHandler();
  return handler;
}

@implementation NCDownloads {
  __weak id<NCDownloadsObserver> _observer;
  NSMutableArray<NCDownloadItem*>* _items;
  std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> _callbacks;
  NSMutableDictionary<NSNumber*, NSString*>* _names;  // the name Chromium suggested before the download began
}

+ (NCDownloads*)shared {
  static NCDownloads* d = [[NCDownloads alloc] initPrivate];
  return d;
}

- (instancetype)initPrivate {
  if ((self = [super init])) { _items = [NSMutableArray array]; _names = [NSMutableDictionary dictionary]; }
  return self;
}

- (NSArray<NCDownloadItem*>*)items { return [_items copy]; }

- (void)startWithObserver:(id<NCDownloadsObserver>)observer {
  _observer = observer;
  // Existing items are announced inside this call, through the handler.
  if (NC_TEST_FLAG("NOCHE_TEST_DL_NOPROFILE")) return;  // negative control: no profile level handler, so downloads without a tab are not reported
  if (CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext()) context->SetDownloadHandler(NCDownloadHandlerInstance());
}

- (void)updated:(CefRefPtr<CefDownloadItem>)item callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  if (!item->IsValid()) return;
  NCDownloadItem* d = [[NCDownloadItem alloc] initPrivate];
  d.identifier = item->GetId();
  d.url = Str(item->GetURL());
  d.fullPath = Str(item->GetFullPath());
  // The engine's own suggested name is the intermediate file's ("Unconfirmed 123.crdownload") while the download runs: the name Chromium suggested
  // before it began is the display name, and the final file's name (a " (1)" suffix included) once it is complete.
  // A canceled item keeps the name its earlier updates had (the engine's own is the intermediate file's).
  NSUInteger known = [_items indexOfObjectPassingTest:^BOOL(NCDownloadItem* i, NSUInteger, BOOL*) { return i.identifier == item->GetId(); }];
  d.suggestedName = _names[@(d.identifier)] ?: (known != NSNotFound ? _items[known].suggestedName : Str(item->GetSuggestedFileName()));
  if (item->IsComplete() || !d.suggestedName.length) d.suggestedName = d.fullPath.lastPathComponent;
  // A download restored from the last session has no name of Chromium's suggesting, only the intermediate file's: the address's last component
  // stands in for the target name (shortcut: the real target name is not in the CEF API, a Content-Disposition name is lost until it completes).
  if (!_names[@(d.identifier)] && !item->IsComplete() && [d.suggestedName hasSuffix:@".crdownload"]) {
    NSURL* address = [d.url hasPrefix:@"http"] ? [NSURL URLWithString:d.url] : nil;
    NSString* fromURL = [address.lastPathComponent stringByRemovingPercentEncoding];
    if (!fromURL.length || [fromURL isEqualToString:@"/"]) fromURL = address.host;  // a bare host address has no path component
    if (fromURL.length) d.suggestedName = fromURL;
  }
  d.receivedBytes = item->GetReceivedBytes();
  d.totalBytes = item->GetTotalBytes();
  d.percent = item->GetPercentComplete();
  d.speed = item->GetCurrentSpeed();
  // A download restored after a quit is interrupted and paused (resumable): it reads as paused, the state a Resume button belongs to.
  d.state = item->IsComplete() ? NCDownloadStateComplete : item->IsCanceled() ? NCDownloadStateCanceled
          : item->IsPaused() ? NCDownloadStatePaused : item->IsInterrupted() ? NCDownloadStateInterrupted : NCDownloadStateInProgress;
  if (d.state == NCDownloadStateComplete && NC_TEST_FLAG("NOCHE_TEST_DL_DROP")) return;  // negative control: the completion never reaches the observer
  // A finished or canceled download takes no more commands; an interrupted one can still be resumed.
  if (d.state == NCDownloadStateComplete || d.state == NCDownloadStateCanceled) { _callbacks.erase(d.identifier); [_names removeObjectForKey:@(d.identifier)]; }
  else _callbacks[d.identifier] = callback;
  NSUInteger at = [_items indexOfObjectPassingTest:^BOOL(NCDownloadItem* i, NSUInteger, BOOL*) { return i.identifier == d.identifier; }];
  if (at == NSNotFound) [_items addObject:d]; else _items[at] = d;
  dispatch_async(dispatch_get_main_queue(), ^{ [self->_observer downloads:self didUpdate:d]; });
}

- (void)willDownload:(uint32_t)identifier name:(NSString*)name { _names[@(identifier)] = name; }

- (void)pause:(uint32_t)identifier { auto i = _callbacks.find(identifier); if (i != _callbacks.end()) i->second->Pause(); }
- (void)resume:(uint32_t)identifier { auto i = _callbacks.find(identifier); if (i != _callbacks.end()) i->second->Resume(); }
- (void)cancel:(uint32_t)identifier { auto i = _callbacks.find(identifier); if (i != _callbacks.end()) i->second->Cancel(); }

- (NSInteger)pauseAllForQuit {
  NSInteger asked = 0;
  for (NCDownloadItem* d in _items) {
    if (d.state != NCDownloadStateInProgress) continue;
    [self pause:d.identifier];
    asked++;
  }
  return asked;
}

@end
