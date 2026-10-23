// Spike S3: media and platform features (Widevine, PiP, spellcheck suggestions, audio state, mute). Throwaway code.
// Usage: --style alloy|chrome --url <media.html url> --out <dir>. Checks run on a worker thread; CDP sends hop to the UI thread.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import "CefBridge.h"
#include <cmath>
#include <mutex>
#include "include/cef_audio_handler.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/views/cef_fill_layout.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_browser_view_delegate.h"
#include "include/views/cef_window.h"
#include "include/views/cef_window_delegate.h"

static double NowMs() { return NSProcessInfo.processInfo.systemUptime * 1000.0; }
static NSString *g_out, *g_style;
static NSFileHandle* g_log;
static NSCondition* g_cond = [NSCondition new];
static NSMutableDictionary<NSNumber*, NSDictionary*>* g_resp = [NSMutableDictionary new];
static CefRefPtr<CefBrowser> g_browser;
static CefRefPtr<CefRegistration> g_reg;
static CefRefPtr<CefWindow> g_cefwin;
static NSWindow* g_nswin;
static int g_id = 0;
static bool g_loaded = false, g_chrome = false, g_noaudio = false;

static void Say(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Say(NSString* fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  NSString* line = [NSString stringWithFormat:@"[S3 %@ %.1f] %@\n", g_style, NowMs(), s];
  fputs(line.UTF8String, stderr);
  fflush(stderr);
  [g_log writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
}

// ---- audio (M4, M5) ----
static std::mutex g_amu;
static int g_a_started = 0, g_a_stopped = 0, g_a_err = 0, g_a_channels = 0;
static long g_a_packets = 0, g_a_frames = 0;
static double g_a_sumsq = 0;  // reset by the checks to measure a window

class Audio : public CefAudioHandler {
 public:
  void OnAudioStreamStarted(CefRefPtr<CefBrowser>, const CefAudioParameters& p, int ch) override {
    { std::lock_guard<std::mutex> l(g_amu); g_a_started++; g_a_channels = ch; }
    Say(@"AUDIO started rate=%d channels=%d frames_per_buffer=%d", p.sample_rate, ch, p.frames_per_buffer);
  }
  void OnAudioStreamPacket(CefRefPtr<CefBrowser>, const float** d, int frames, int64_t) override {
    std::lock_guard<std::mutex> l(g_amu);
    g_a_packets++; g_a_frames += frames;
    for (int c = 0; c < g_a_channels; c++) for (int i = 0; i < frames; i++) g_a_sumsq += (double)d[c][i] * d[c][i];
  }
  void OnAudioStreamStopped(CefRefPtr<CefBrowser>) override {
    { std::lock_guard<std::mutex> l(g_amu); g_a_stopped++; }
    Say(@"AUDIO stopped");
  }
  void OnAudioStreamError(CefRefPtr<CefBrowser>, const CefString& m) override {
    { std::lock_guard<std::mutex> l(g_amu); g_a_err++; }
    Say(@"AUDIO error %s", m.ToString().c_str());
  }
  IMPLEMENT_REFCOUNTING(Audio);
};
struct AStat { long packets, frames; double rms; int started, stopped; };
static AStat AReset() {
  std::lock_guard<std::mutex> l(g_amu);
  AStat s{g_a_packets, g_a_frames, g_a_frames ? sqrt(g_a_sumsq / (g_a_frames * (double)std::max(g_a_channels, 1))) : 0, g_a_started, g_a_stopped};
  g_a_packets = 0; g_a_frames = 0; g_a_sumsq = 0;
  return s;
}

// ---- context menu (M3) ----
static NSString* g_ctx = nil;  // result of the last menu
class Ctx : public CefContextMenuHandler {
 public:
  void OnBeforeContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams> p, CefRefPtr<CefMenuModel> m) override {
    std::vector<CefString> sug;
    bool has = p->GetDictionarySuggestions(sug);
    NSMutableString* s = [NSMutableString stringWithFormat:@"misspelled=%s editable=%d spellcheck_enabled=%d GetDictionarySuggestions=%d count=%zu [",
                          p->GetMisspelledWord().ToString().c_str(), p->IsEditable(), p->IsSpellCheckEnabled(), has, sug.size()];
    for (auto& x : sug) [s appendFormat:@"%s,", x.ToString().c_str()];
    [s appendFormat:@"] menu_items=%zu", m->GetCount()];
    Say(@"CTXMENU %@", s);
    [g_cond lock]; g_ctx = s; [g_cond broadcast]; [g_cond unlock];
  }
  // Swallow the native menu so no menu tracking loop is left open.
  bool RunContextMenu(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefContextMenuParams>, CefRefPtr<CefMenuModel>,
                      CefRefPtr<CefRunContextMenuCallback> cb) override {
    cb->Cancel();
    return true;
  }
  IMPLEMENT_REFCOUNTING(Ctx);
};

class Obs : public CefDevToolsMessageObserver {
 public:
  bool OnDevToolsMessage(CefRefPtr<CefBrowser>, const void* m, size_t n) override {
    NSData* d = [NSData dataWithBytes:m length:n];
    NSDictionary* j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![j isKindOfClass:NSDictionary.class]) return false;
    if (j[@"id"]) {
      NSMutableDictionary* e = [j mutableCopy];
      [g_cond lock]; g_resp[j[@"id"]] = e; [g_cond broadcast]; [g_cond unlock];
    }
    return true;
  }
  IMPLEMENT_REFCOUNTING(Obs);
};

static void Created(CefRefPtr<CefBrowser> b) {
  g_browser = b;
  g_reg = b->GetHost()->AddDevToolsMessageObserver(new Obs());
  Say(@"BROWSER created id=%d alloy=%d", b->GetIdentifier(), (int)(b->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_ALLOY));
}

class Client : public CefClient, public CefLoadHandler, public CefLifeSpanHandler, public CefDisplayHandler {
 public:
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefAudioHandler> GetAudioHandler() override { return g_noaudio ? nullptr : audio_; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return ctx_; }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> f, int s) override {
    if (!f->IsMain()) return;
    Say(@"LOADEND status=%d", s);
    [g_cond lock]; g_loaded = true; [g_cond broadcast]; [g_cond unlock];
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, ErrorCode c, const CefString& t, const CefString& u) override {
    Say(@"LOADERROR %d %s %s", (int)c, t.ToString().c_str(), u.ToString().c_str());
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> b) override { if (!g_browser) Created(b); }
  bool DoClose(CefRefPtr<CefBrowser>) override { Say(@"DoClose"); return false; }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override { Say(@"OnBeforeClose"); }
 private:
  CefRefPtr<CefAudioHandler> audio_ = new Audio();
  CefRefPtr<CefContextMenuHandler> ctx_ = new Ctx();
  IMPLEMENT_REFCOUNTING(Client);
};

// ---- worker-thread helpers (same shape as the S4 spike) ----
static NSDictionary* Call(NSString* method, NSDictionary* params) {
  __block int myid;
  NSMutableDictionary* msg = [@{@"method" : method, @"params" : params ?: @{}} mutableCopy];
  dispatch_sync(dispatch_get_main_queue(), ^{
    myid = ++g_id;
    msg[@"id"] = @(myid);
    NSData* d = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
    g_browser->GetHost()->SendDevToolsMessage(d.bytes, d.length);
  });
  NSDate* dl = [NSDate dateWithTimeIntervalSinceNow:15];
  [g_cond lock];
  while (!g_resp[@(myid)] && [g_cond waitUntilDate:dl]) {}
  NSDictionary* r = g_resp[@(myid)];
  [g_cond unlock];
  if (!r) Say(@"TIMEOUT %@", method);
  return r;
}
static id Eval(NSString* expr) {
  NSDictionary* r = Call(@"Runtime.evaluate", @{@"expression" : expr, @"returnByValue" : @YES});
  return r[@"result"][@"result"][@"value"];
}
static void MouseAt(double x, double y, NSString* btn, int buttons) {
  Call(@"Input.dispatchMouseEvent", @{@"type" : @"mouseMoved", @"x" : @(x), @"y" : @(y)});
  Call(@"Input.dispatchMouseEvent", @{@"type" : @"mousePressed", @"x" : @(x), @"y" : @(y), @"button" : btn, @"buttons" : @(buttons), @"clickCount" : @1});
  Call(@"Input.dispatchMouseEvent", @{@"type" : @"mouseReleased", @"x" : @(x), @"y" : @(y), @"button" : btn, @"buttons" : @0, @"clickCount" : @1});
}
static NSArray<NSNumber*>* Center(NSString* sel) {
  return Eval([NSString stringWithFormat:@"(()=>{const r=document.querySelector('%@').getBoundingClientRect();return [r.left+r.width/2,r.top+r.height/2]})()", sel]);
}
static void ClickSel(NSString* sel) { NSArray* c = Center(sel); MouseAt([c[0] doubleValue], [c[1] doubleValue], @"left", 1); }
static NSString* Text(NSString* id_) { return Eval([NSString stringWithFormat:@"document.getElementById('%@').textContent", id_]); }
static NSString* WaitText(NSString* id_, double sec) {
  for (double t = 0; t < sec; t += 0.2) { NSString* s = Text(id_); if (s.length) return s; usleep(200000); }
  return @"";
}
static void Shot(NSString* name) {
  __block int num = 0;
  dispatch_sync(dispatch_get_main_queue(), ^{ num = (int)g_nswin.windowNumber; });
  NSTask* t = [NSTask launchedTaskWithLaunchPath:@"/usr/sbin/screencapture"
                                       arguments:@[ @"-x", @"-o", @"-l", [NSString stringWithFormat:@"%d", num], [g_out stringByAppendingPathComponent:name] ]];
  [t waitUntilExit];
  Say(@"SHOT %@ windowNumber=%d status=%d", name, num, t.terminationStatus);
}
static void Pmset(NSString* name) {
  NSTask* t = [NSTask new];
  t.launchPath = @"/bin/sh";
  t.arguments = @[ @"-c", [NSString stringWithFormat:@"/usr/bin/pmset -g assertions > '%@' 2>&1", [g_out stringByAppendingPathComponent:name]] ];
  [t launch]; [t waitUntilExit];
}
static void WindowList(NSString* tag) {
  NSArray* l = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
  int pid = getpid();
  for (NSDictionary* w in l) {
    if ([w[(id)kCGWindowOwnerPID] intValue] != pid) continue;
    Say(@"WINDOWLIST %@ num=%@ layer=%@ onscreen=%@ bounds=%@ name='%@'", tag, w[(id)kCGWindowNumber], w[(id)kCGWindowLayer],
        w[(id)kCGWindowIsOnscreen], [NSString stringWithFormat:@"%@x%@@%@,%@", w[(id)kCGWindowBounds][@"Width"], w[(id)kCGWindowBounds][@"Height"], w[(id)kCGWindowBounds][@"X"], w[(id)kCGWindowBounds][@"Y"]], w[(id)kCGWindowName] ?: @"");
  }
}

static void Checks() {
  NSMutableString* sum = [NSMutableString new];
  void (^V)(NSString*, NSString*, NSString*) = ^(NSString* c, NSString* r, NSString* note) {
    Say(@"RESULT %@ %@ %@", c, r, note);
    [sum appendFormat:@"%@ %@ %@\n", c, r, note];
  };
  NSDate* dl = [NSDate dateWithTimeIntervalSinceNow:20];
  [g_cond lock]; while (!g_loaded && [g_cond waitUntilDate:dl]) {} [g_cond unlock];
  sleep(1);
  Say(@"loaded, title=%@ ua=%@", Eval(@"document.title"), Eval(@"navigator.userAgent"));
  Shot(@"loaded.png");

  // M1
  ClickSel(@"#wv");
  NSString* wv = WaitText(@"wvres", 15);
  V(@"M1", [wv hasPrefix:@"OK"] ? @"PASS" : @"FAIL", wv.length ? wv : @"no result within 15 s");

  // M4 + M5: a click on Play is the user gesture; audible (unmuted) playback of a 440 Hz tone.
  AReset();
  ClickSel(@"#play");
  NSString* pr = WaitText(@"play_res", 5);
  sleep(2);
  AStat a1 = AReset();
  NSNumber* ct = Eval(@"document.getElementById('v').currentTime");
  Pmset(@"pmset-unmuted.txt");
  V(@"M4", a1.started > 0 ? @"PASS" : @"FAIL", [NSString stringWithFormat:@"callback=CefAudioHandler::OnAudioStreamStarted play_result=%@ currentTime=%.2f started=%d packets=%ld frames=%ld rms=%.4f", pr, ct.doubleValue, a1.started, a1.packets, a1.frames, a1.rms]);
  dispatch_sync(dispatch_get_main_queue(), ^{ g_browser->GetHost()->SetAudioMuted(true); });
  usleep(500000);
  AReset();
  sleep(2);
  Pmset(@"pmset-muted.txt");
  AStat a2 = AReset();
  __block bool muted;
  dispatch_sync(dispatch_get_main_queue(), ^{ muted = g_browser->GetHost()->IsAudioMuted(); });
  NSNumber* ct2 = Eval(@"document.getElementById('v').currentTime");
  NSNumber* paused = Eval(@"document.getElementById('v').paused");
  // The OnAudioStreamPacket tap sits before the mute stage, so unchanged packets do not prove audible output; silence needs a hardware or ear check.
  // Device level: coreaudiod lists an "audio-out" resource while a stream reaches the output device (pmset assertions).
  NSString* pu = [NSString stringWithContentsOfFile:[g_out stringByAppendingPathComponent:@"pmset-unmuted.txt"] encoding:NSUTF8StringEncoding error:nil];
  NSString* pm = [NSString stringWithContentsOfFile:[g_out stringByAppendingPathComponent:@"pmset-muted.txt"] encoding:NSUTF8StringEncoding error:nil];
  bool devU = [pu containsString:@"audio-out"], devM = [pm containsString:@"audio-out"];
  NSString* r5 = !muted ? @"FAIL" : ((devU && !devM) || (a2.rms < 0.0001 && a1.rms > 0.01) ? @"PASS" : @"INCONCLUSIVE");
  V(@"M5", r5, [NSString stringWithFormat:@"IsAudioMuted=%d unmuted_rms=%.4f unmuted_packets=%ld muted_rms=%.6f muted_packets=%ld stopped=%d video_paused=%@ currentTime %.2f->%.2f (clip loops every 4 s, video kept playing) coreaudiod_audio-out unmuted=%d muted=%d (pmset-unmuted.txt, pmset-muted.txt) audio_handler=%d", muted, a1.rms, a1.packets, a2.rms, a2.packets, a2.stopped, paused, ct.doubleValue, ct2.doubleValue, devU, devM, (int)!g_noaudio]);

  // M3: focus the field, right-click on the word.
  ClickSel(@"#ce");
  usleep(500000);
  NSArray* wc = Eval(@"(()=>{const n=document.getElementById('ce').firstChild;const r=document.createRange();r.setStart(n,0);r.setEnd(n,7);const b=r.getBoundingClientRect();return [b.left+b.width/2,b.top+b.height/2]})()");
  [g_cond lock]; g_ctx = nil; [g_cond unlock];
  MouseAt([wc[0] doubleValue], [wc[1] doubleValue], @"right", 2);
  dl = [NSDate dateWithTimeIntervalSinceNow:8];
  [g_cond lock]; while (!g_ctx && [g_cond waitUntilDate:dl]) {} NSString* cx = g_ctx; [g_cond unlock];
  V(@"M3", [cx containsString:@"count=0"] || !cx ? @"FAIL" : (([cx containsString:@"GetDictionarySuggestions=1"]) ? @"PASS" : @"FAIL"), cx ?: @"OnBeforeContextMenu never fired");

  // M2: PiP via a real click.
  [g_cond lock]; g_ctx = nil; [g_cond unlock];
  ClickSel(@"#pip");
  NSString* pp = WaitText(@"pipres", 8);
  sleep(1);
  NSString* pel = Eval(@"String(document.pictureInPictureElement&&document.pictureInPictureElement.id)");
  NSString* en = Eval(@"'enabled='+document.pictureInPictureEnabled");
  WindowList(@"after-pip");
  Shot(@"pip.png");
  V(@"M2", [pp hasPrefix:@"OK"] ? @"PASS" : @"FAIL", [NSString stringWithFormat:@"%@ pictureInPictureElement=%@ %@", pp.length ? pp : @"no result within 8 s", pel, en]);

  [sum writeToFile:[g_out stringByAppendingPathComponent:@"summary.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (g_chrome && g_cefwin) g_cefwin->Close(); else if (g_browser) g_browser->GetHost()->CloseBrowser(true);
  });
  sleep(3);  // OnBeforeClose does not reliably fire in these spikes, so quit explicitly
  Say(@"exit(0) after grace period");
  exit(0);
}

class BVD : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  void OnBrowserCreated(CefRefPtr<CefBrowserView>, CefRefPtr<CefBrowser> b) override { if (!g_browser) Created(b); }
  IMPLEMENT_REFCOUNTING(BVD);
};
static CefRefPtr<CefBrowserView> g_bv;
class WD : public CefWindowDelegate {
 public:
  void OnWindowCreated(CefRefPtr<CefWindow> w) override {
    g_cefwin = w;
    w->AddChildView(g_bv);
    w->SetToFillLayout();
    w->Show();
    g_nswin = ((__bridge NSView*)w->GetWindowHandle()).window;
    g_nswin.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
    w->Activate();
    Say(@"WINDOW created %@", g_nswin);
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    Say(@"WINDOW destroyed");
    g_cefwin = nullptr; g_bv = nullptr;
  }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(100, 100, 900, 640); }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  IMPLEMENT_REFCOUNTING(WD);
};

@interface S3Delegate : NSObject <NSApplicationDelegate>
@end
@implementation S3Delegate
- (void)applicationDidFinishLaunching:(NSNotification*)n {
  NSArray<NSString*>* args = NSProcessInfo.processInfo.arguments;
  NSString* url = nil;
  for (NSUInteger i = 1; i + 1 < args.count; i++) {
    if ([args[i] isEqualToString:@"--url"]) url = args[i + 1];
    else if ([args[i] isEqualToString:@"--out"]) g_out = args[i + 1];
    else if ([args[i] isEqualToString:@"--style"]) g_style = args[i + 1];
  }
  g_noaudio = [args containsObject:@"--no-audio-handler"];
  if (!url || !g_out || !([g_style isEqualToString:@"alloy"] || [g_style isEqualToString:@"chrome"])) { fprintf(stderr, "need --style alloy|chrome --url --out\n"); exit(2); }
  g_chrome = [g_style isEqualToString:@"chrome"];
  [NSFileManager.defaultManager createDirectoryAtPath:g_out withIntermediateDirectories:YES attributes:nil error:nil];
  NSString* lp = [g_out stringByAppendingPathComponent:@"run.log"];
  [@"" writeToFile:lp atomically:YES encoding:NSUTF8StringEncoding error:nil];
  g_log = [NSFileHandle fileHandleForWritingAtPath:lp];
  NSString* cache = [NSHomeDirectory() stringByAppendingPathComponent:[@"Library/Application Support/Noche Spikes/s3-" stringByAppendingString:g_style]];
  [NSFileManager.defaultManager removeItemAtPath:cache error:nil];
  [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
  Say(@"cache=%@", cache);
  NSError* err = nil;
  if (![NCEngine startWithCachePath:cache error:&err]) { Say(@"ENGINE FAIL %@", err); exit(4); }
  if (g_chrome) {
    g_bv = CefBrowserView::CreateBrowserView(new Client(), url.UTF8String, CefBrowserSettings(), nullptr, nullptr, new BVD());
    CefWindow::CreateTopLevelWindow(new WD());
  } else {
    CGFloat sh = NSScreen.screens.firstObject.frame.size.height;
    g_nswin = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, sh - 100 - 640, 900, 640)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                            backing:NSBackingStoreBuffered defer:NO];
    g_nswin.releasedWhenClosed = NO;
    g_nswin.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
    NSView* v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 640)];
    g_nswin.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 640)];
    [g_nswin.contentView addSubview:v];
    [g_nswin makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    CefWindowInfo info;
    info.SetAsChild((__bridge CefWindowHandle)v, CefRect(0, 0, 900, 640));
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserHost::CreateBrowserSync(info, new Client(), url.UTF8String, CefBrowserSettings(), nullptr, nullptr);
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ Checks(); });
  [NSTimer scheduledTimerWithTimeInterval:120 repeats:NO block:^(NSTimer*) { Say(@"WATCHDOG exit"); exit(3); }];
}
@end

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    NCApplication* app = (NCApplication*)NCApplication.sharedApplication;
    static S3Delegate* d = [S3Delegate new];
    app.delegate = d;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app run];
  }
  return 0;
}
