#import <Foundation/Foundation.h>
#include "NCInternal.h"
#include "include/cef_browser_process_handler.h"

namespace {

constexpr NSTimeInterval kMaxDelay = 1.0 / 30.0;

bool g_active = false;
bool g_in_work = false;
bool g_again = false;
NSTimer* g_fallback = nil;
NSTimer* g_delayed = nil;

void DoWork();

NSTimer* AddTimer(NSTimeInterval interval, bool repeats) {
  NSTimer* t = [NSTimer timerWithTimeInterval:interval repeats:repeats block:^(NSTimer*) { DoWork(); }];
  [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
  return t;
}

void DoWork() {
  if (!g_active) return;
  if (g_in_work) {  // no nested CefDoMessageLoopWork
    g_again = true;
    return;
  }
  g_in_work = true;
  do {
    g_again = false;
    CefDoMessageLoopWork();
  } while (g_again && g_active);
  g_in_work = false;
}

void ScheduleOnMain(int64_t delay_ms) {
  if (!g_active) return;
  [g_delayed invalidate];
  g_delayed = nil;
  if (delay_ms <= 0) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ DoWork(); });
    CFRunLoopWakeUp(CFRunLoopGetMain());
  } else {
    g_delayed = AddTimer(std::min<NSTimeInterval>(delay_ms / 1000.0, kMaxDelay), false);
  }
}

class NCApp : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  // An ad-hoc signed build blocks on the keychain prompt for the cookie key, which stalls every
  // request. Only builds marked NocheDevBuild (written by scripts/build-app.sh) use a mock keychain.
  // shortcut: real keychain use needs a stable signing identity, remove the flag once builds are signed.
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> line) override {
    if ([[NSBundle.mainBundle objectForInfoDictionaryKey:@"NocheDevBuild"] boolValue]) {
      line->AppendSwitch("use-mock-keychain");
    }
  }

  // May arrive on any thread.
  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ ScheduleOnMain(delay_ms); });
    CFRunLoopWakeUp(CFRunLoopGetMain());
  }

 private:
  IMPLEMENT_REFCOUNTING(NCApp);
};

}  // namespace

CefRefPtr<CefApp> NCCreateApp() { return new NCApp(); }

void NCPumpStart() {
  g_active = true;
  g_fallback = AddTimer(kMaxDelay, true);
}

void NCPumpStop() {
  g_active = false;
  [g_fallback invalidate];
  [g_delayed invalidate];
  g_fallback = g_delayed = nil;
}
