// Spike S4: agent loop over CDP on an Alloy browser. Throwaway code.
// Usage: --agent-url <url of agent.html with ?frame=...> --out <dir>. Checks D1..D5 run on a worker thread;
// CDP sends hop to the main (CEF UI) thread, responses come back through the observer.
#import <AppKit/AppKit.h>
#import "CefBridge.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"

static double NowMs() { return NSProcessInfo.processInfo.systemUptime * 1000.0; }
static NSString* g_out;
static NSFileHandle* g_cdplog;
static NSCondition* g_cond = [NSCondition new];
static NSMutableDictionary<NSNumber*, NSDictionary*>* g_resp = [NSMutableDictionary new];
static NSMutableArray<NSDictionary*>* g_events = [NSMutableArray new];
static CefRefPtr<CefBrowser> g_browser;
static CefRefPtr<CefRegistration> g_reg;
static int g_id = 0;
static bool g_loaded = false;
static NSString* g_title = @"";
static NSView* g_view;

static void Raw(NSString* s) {  // raw log line (truncates huge payloads such as screenshot data)
  if (s.length > 40000) s = [NSString stringWithFormat:@"%@...[truncated, %lu chars total]", [s substringToIndex:40000], (unsigned long)s.length];
  [g_cdplog writeData:[[s stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
}
static void Say(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Say(NSString* fmt, ...) {
  va_list ap; va_start(ap, fmt);
  NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  fprintf(stderr, "[S4 %.1f] %s\n", NowMs(), s.UTF8String);
  fflush(stderr);
  Raw([NSString stringWithFormat:@"# %@", s]);
}

class Obs : public CefDevToolsMessageObserver {
 public:
  bool OnDevToolsMessage(CefRefPtr<CefBrowser>, const void* m, size_t n) override {
    NSData* d = [NSData dataWithBytes:m length:n];
    NSDictionary* j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    Raw([NSString stringWithFormat:@"< %@", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]]);
    if (![j isKindOfClass:NSDictionary.class]) return false;
    NSMutableDictionary* e = [j mutableCopy];
    e[@"_t"] = @(NowMs());
    [g_cond lock];
    if (j[@"id"]) g_resp[j[@"id"]] = e; else [g_events addObject:e];
    [g_cond broadcast];
    [g_cond unlock];
    return true;
  }
  IMPLEMENT_REFCOUNTING(Obs);
};

class Client : public CefClient, public CefLoadHandler, public CefDisplayHandler, public CefLifeSpanHandler {
 public:
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> f, int s) override {
    if (!f->IsMain()) return;
    [g_cond lock]; g_loaded = true; [g_cond broadcast]; [g_cond unlock];
  }
  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& t) override {
    Say(@"TITLE %s", t.ToString().c_str());
    [g_cond lock]; g_title = @(t.ToString().c_str()); [g_cond unlock];
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    g_browser = b;
    g_reg = b->GetHost()->AddDevToolsMessageObserver(new Obs());
    Say(@"BROWSER created id=%d alloy=%d", b->GetIdentifier(), (int)(b->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_ALLOY));
  }
  bool DoClose(CefRefPtr<CefBrowser>) override { Say(@"DoClose"); return false; }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    g_reg = nullptr; g_browser = nullptr;
    Say(@"browser closed, exiting");
    dispatch_async(dispatch_get_main_queue(), ^{ [NCEngine shutdown]; exit(0); });
  }
  IMPLEMENT_REFCOUNTING(Client);
};

// ---- worker-thread helpers ----
static NSDictionary* Call(NSString* method, NSDictionary* params, NSString* sid, double* ms) {
  __block int myid;
  NSMutableDictionary* msg = [@{@"method" : method, @"params" : params ?: @{}} mutableCopy];
  if (sid) msg[@"sessionId"] = sid;
  __block double t0;
  dispatch_sync(dispatch_get_main_queue(), ^{
    myid = ++g_id;
    msg[@"id"] = @(myid);
    NSData* d = [NSJSONSerialization dataWithJSONObject:msg options:0 error:nil];
    Raw([NSString stringWithFormat:@"> %@", [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]]);
    t0 = NowMs();
    g_browser->GetHost()->SendDevToolsMessage(d.bytes, d.length);
  });
  NSDate* dl = [NSDate dateWithTimeIntervalSinceNow:15];
  [g_cond lock];
  while (!g_resp[@(myid)] && [g_cond waitUntilDate:dl]) {}
  NSDictionary* r = g_resp[@(myid)];
  [g_cond unlock];
  if (!r) { Say(@"TIMEOUT %@", method); return nil; }
  if (ms) *ms = [r[@"_t"] doubleValue] - t0;
  return r;
}
static NSDictionary* Res(NSDictionary* r) { return r[@"result"] ?: @{}; }

static NSDictionary* WaitEvent(NSString* method, double sec, BOOL (^pred)(NSDictionary*)) {
  NSDate* dl = [NSDate dateWithTimeIntervalSinceNow:sec];
  [g_cond lock];
  for (;;) {
    for (NSDictionary* e in g_events)
      if ([e[@"method"] isEqualToString:method] && (!pred || pred(e))) { [g_cond unlock]; return e; }
    if (![g_cond waitUntilDate:dl]) break;
  }
  [g_cond unlock];
  return nil;
}
static void WaitLoad() {
  NSDate* dl = [NSDate dateWithTimeIntervalSinceNow:20];
  [g_cond lock];
  while (!g_loaded && [g_cond waitUntilDate:dl]) {}
  [g_cond unlock];
}
static id Eval(NSString* expr, NSString* sid) {
  NSDictionary* r = Call(@"Runtime.evaluate", @{@"expression" : expr, @"returnByValue" : @YES}, sid, nil);
  return Res(r)[@"result"][@"value"];
}
static void Click(double x, double y, NSString* sid) {
  Call(@"Input.dispatchMouseEvent", @{@"type" : @"mouseMoved", @"x" : @(x), @"y" : @(y)}, sid, nil);
  Call(@"Input.dispatchMouseEvent", @{@"type" : @"mousePressed", @"x" : @(x), @"y" : @(y), @"button" : @"left", @"buttons" : @1, @"clickCount" : @1}, sid, nil);
  Call(@"Input.dispatchMouseEvent", @{@"type" : @"mouseReleased", @"x" : @(x), @"y" : @(y), @"button" : @"left", @"buttons" : @0, @"clickCount" : @1}, sid, nil);
}
// Center of a selector's content box, in CSS px of the page that owns the DOM session.
static NSArray<NSNumber*>* Center(NSString* sel, NSString* sid) {
  NSDictionary* doc = Res(Call(@"DOM.getDocument", @{@"depth" : @0}, sid, nil));
  NSNumber* root = doc[@"root"][@"nodeId"];
  NSNumber* nid = Res(Call(@"DOM.querySelector", @{@"nodeId" : root, @"selector" : sel}, sid, nil))[@"nodeId"];
  if (!nid.intValue) return nil;
  NSArray* q = Res(Call(@"DOM.getBoxModel", @{@"nodeId" : nid}, sid, nil))[@"model"][@"content"];
  if (q.count != 8) return nil;
  double x = ([q[0] doubleValue] + [q[2] doubleValue] + [q[4] doubleValue] + [q[6] doubleValue]) / 4;
  double y = ([q[1] doubleValue] + [q[3] doubleValue] + [q[5] doubleValue] + [q[7] doubleValue]) / 4;
  return @[ @(x), @(y) ];
}
static NSString* Title() { return Eval(@"document.title", nil); }
static double Median(NSMutableArray<NSNumber*>* a) {
  [a sortUsingSelector:@selector(compare:)];
  return ([a[4] doubleValue] + [a[5] doubleValue]) / 2;
}

static void Checks() {
  NSMutableString* sum = [NSMutableString new];
  void (^Verdict)(NSString*, BOOL, NSString*) = ^(NSString* c, BOOL ok, NSString* note) {
    Say(@"RESULT %@ %@ %@", c, ok ? @"PASS" : @"FAIL", note);
    [sum appendFormat:@"%@ %@ %@\n", c, ok ? @"PASS" : @"FAIL", note];
  };
  WaitLoad();
  Say(@"page loaded, title=%@", Title());
  if (getenv("S4_CLOSE_ONLY")) { dispatch_async(dispatch_get_main_queue(), ^{ g_browser->GetHost()->CloseBrowser(false); }); sleep(3); exit(0); }

  // D1
  Call(@"Accessibility.enable", nil, nil, nil);
  NSDictionary* ax = Res(Call(@"Accessibility.getFullAXTree", nil, nil, nil));
  NSString *inRole = nil, *inName = nil, *btRole = nil, *btName = nil;
  NSUInteger nodes = [ax[@"nodes"] count];
  for (NSDictionary* n in ax[@"nodes"]) {
    NSString* role = n[@"role"][@"value"];
    NSString* name = n[@"name"][@"value"];
    if ([role isEqualToString:@"textbox"] && [name isEqualToString:@"Name field"]) { inRole = role; inName = name; }
    if ([role isEqualToString:@"button"] && [name isEqualToString:@"Go"]) { btRole = role; btName = name; }
  }
  [ax[@"nodes"] writeToFile:[g_out stringByAppendingPathComponent:@"d1-ax-nodes.plist"] atomically:YES];
  Verdict(@"D1", inRole && btRole, [NSString stringWithFormat:@"nodes=%lu input=(%@,%@) button=(%@,%@)", (unsigned long)nodes, inRole, inName, btRole, btName]);

  // D2
  NSArray* ic = Center(@"#name", nil);
  Click([ic[0] doubleValue], [ic[1] doubleValue], nil);
  Call(@"Input.insertText", @{@"text" : @"hello"}, nil, nil);
  NSString* val = Eval(@"document.getElementById('name').value", nil);
  NSArray* bc = Center(@"#go", nil);
  Click([bc[0] doubleValue], [bc[1] doubleValue], nil);
  NSString* t = Title();
  Verdict(@"D2", [t isEqualToString:@"clicked:hello"], [NSString stringWithFormat:@"input center=(%.1f,%.1f) value=%@ button center=(%.1f,%.1f) title=%@", [ic[0] doubleValue], [ic[1] doubleValue], val, [bc[0] doubleValue], [bc[1] doubleValue], t]);

  // D3
  NSDictionary* shot = Res(Call(@"Page.captureScreenshot", @{@"format" : @"png"}, nil, nil));
  NSData* png = [[NSData alloc] initWithBase64EncodedString:shot[@"data"] options:0];
  [png writeToFile:[g_out stringByAppendingPathComponent:@"d3.png"] atomically:YES];
  const uint8_t* p = (const uint8_t*)png.bytes;
  int pw = png.length > 24 ? (p[16] << 24 | p[17] << 16 | p[18] << 8 | p[19]) : 0;
  int ph = png.length > 24 ? (p[20] << 24 | p[21] << 16 | p[22] << 8 | p[23]) : 0;
  __block NSSize vs; __block CGFloat sc;
  dispatch_sync(dispatch_get_main_queue(), ^{ vs = g_view.bounds.size; sc = g_view.window.backingScaleFactor; });
  int ew = (int)(vs.width * sc), eh = (int)(vs.height * sc);
  NSString* inner = Eval(@"innerWidth+'x'+innerHeight+' dpr='+devicePixelRatio+' vis='+document.visibilityState", nil);
  Verdict(@"D3", png.length > 8 && p[1] == 'P' && pw == ew && ph == eh, [NSString stringWithFormat:@"png=%dx%d bytes=%lu view=%.0fx%.0f pt scale=%.1f expected=%dx%d page=%@", pw, ph, (unsigned long)png.length, vs.width, vs.height, sc, ew, eh, inner]);

  // D4: auto-attach (flatten) then reload so the iframe is created under the attach rule
  NSDictionary* aa = Call(@"Target.setAutoAttach", @{@"autoAttach" : @YES, @"waitForDebuggerOnStart" : @NO, @"flatten" : @YES}, nil, nil);
  Say(@"setAutoAttach response %@", aa);
  [g_cond lock]; [g_events removeAllObjects]; g_loaded = false; [g_cond unlock];
  Call(@"Page.reload", nil, nil, nil);
  WaitLoad();
  NSDictionary* ev = WaitEvent(@"Target.attachedToTarget", 8, ^BOOL(NSDictionary* e) { return [e[@"params"][@"targetInfo"][@"type"] isEqualToString:@"iframe"]; });
  NSString* sid = ev[@"params"][@"sessionId"];
  NSString* turl = ev[@"params"][@"targetInfo"][@"url"];
  Say(@"attached iframe sid=%@ url=%@", sid, turl);
  BOOL d4 = NO; NSString* d4note = @"no iframe target attached (iframe not out-of-process?)";
  if (sid) {
    for (int i = 0; i < 20 && ![Eval(@"!!document.querySelector('button')", sid) boolValue]; i++) usleep(100000);
    NSString* before = Eval(@"document.querySelector('button').textContent", sid);
    NSArray* fc = Center(@"#fb", sid);          // button center in frame CSS px
    NSArray* oc = Center(@"#f", nil);           // iframe box origin in page CSS px (content box center)
    NSArray* oo = Eval(@"(()=>{const r=document.getElementById('f').getBoundingClientRect();return [r.left+1,r.top+1]})()", nil);  // +1 border
    double px = [oo[0] doubleValue] + [fc[0] doubleValue], py = [oo[1] doubleValue] + [fc[1] doubleValue];
    Say(@"frame button center in frame=(%@,%@) iframe origin=(%@,%@) page coords=(%.1f,%.1f) (iframe box center %@)", fc[0], fc[1], oo[0], oo[1], px, py, oc);
    Click(px, py, nil);  // dispatched on the parent session; Chrome routes by hit test to the OOPIF
    usleep(300000);
    NSString* after = Eval(@"document.querySelector('button').textContent", sid);
    NSString* via = @"parent session";
    if (![after isEqualToString:@"frame-clicked"]) {
      Click([fc[0] doubleValue], [fc[1] doubleValue], sid);  // fallback: dispatch on the iframe session
      usleep(300000);
      after = Eval(@"document.querySelector('button').textContent", sid);
      via = @"iframe session";
    }
    d4 = [after isEqualToString:@"frame-clicked"];
    d4note = [NSString stringWithFormat:@"target=%@ before=%@ after=%@ click dispatched via %@", turl, before, after, via];
  }
  Verdict(@"D4", d4, d4note);

  // D5: 10 round trips per method
  NSMutableString* tm = [NSMutableString stringWithString:@"method\tmedian_ms\tall_ms\n"];
  NSArray* specs = @[
    @[ @"Accessibility.getFullAXTree", @{}, @"" ],
    @[ @"Runtime.evaluate", @{@"expression" : @"document.title", @"returnByValue" : @YES}, @"" ],
    @[ @"DOM.getBoxModel", @{}, @"box" ],
    @[ @"Input.dispatchMouseEvent", @{@"type" : @"mouseMoved", @"x" : @300, @"y" : @300}, @"" ],
    @[ @"Input.insertText", @{@"text" : @"x"}, @"" ],
    @[ @"Page.captureScreenshot", @{@"format" : @"png"}, @"" ],
    @[ @"Runtime.evaluate(iframe session)", @{@"expression" : @"document.title", @"returnByValue" : @YES}, @"sid" ],
  ];
  NSNumber* inputNode = nil;
  { NSDictionary* doc = Res(Call(@"DOM.getDocument", @{@"depth" : @0}, nil, nil));
    inputNode = Res(Call(@"DOM.querySelector", @{@"nodeId" : doc[@"root"][@"nodeId"], @"selector" : @"#name"}, nil, nil))[@"nodeId"]; }
  for (NSArray* s in specs) {
    NSMutableArray<NSNumber*>* a = [NSMutableArray new];
    NSString* m = [s[0] hasPrefix:@"Runtime.evaluate"] ? @"Runtime.evaluate" : s[0];
    NSDictionary* pr = [s[2] isEqualToString:@"box"] ? @{@"nodeId" : inputNode} : s[1];
    NSString* useSid = [s[2] isEqualToString:@"sid"] ? sid : nil;
    if ([s[2] isEqualToString:@"sid"] && !sid) continue;
    for (int i = 0; i < 10; i++) { double ms = 0; Call(m, pr, useSid, &ms); [a addObject:@(ms)]; }
    NSArray* raw = [a copy];
    [tm appendFormat:@"%@\t%.2f\t%@\n", s[0], Median(a), [raw componentsJoinedByString:@","]];
  }
  [tm writeToFile:[g_out stringByAppendingPathComponent:@"d5-timings.tsv"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  Verdict(@"D5", YES, @"timings written to d5-timings.tsv");
  Say(@"TIMINGS\n%@", tm);
  [sum writeToFile:[g_out stringByAppendingPathComponent:@"summary.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  dispatch_async(dispatch_get_main_queue(), ^{ Say(@"CLOSE requested, browser=%d", g_browser != nullptr); if (g_browser) g_browser->GetHost()->CloseBrowser(false); });
  // CloseBrowser reaches DoClose but OnBeforeClose never follows in this harness (see doc); quit path is exit after a grace period.
  sleep(3);
  Say(@"exit(0) after grace period");
  exit(0);
}

@interface S4Delegate : NSObject <NSApplicationDelegate>
@end
@implementation S4Delegate {
  NSWindow* _win;
}
- (void)applicationDidFinishLaunching:(NSNotification*)n {
  NSArray<NSString*>* args = NSProcessInfo.processInfo.arguments;
  NSString* url = nil;
  for (NSUInteger i = 1; i + 1 < args.count; i++) {
    if ([args[i] isEqualToString:@"--agent-url"]) url = args[i + 1];
    else if ([args[i] isEqualToString:@"--out"]) g_out = args[i + 1];
  }
  if (!url || !g_out) { fprintf(stderr, "need --agent-url and --out\n"); exit(2); }
  [NSFileManager.defaultManager createDirectoryAtPath:g_out withIntermediateDirectories:YES attributes:nil error:nil];
  NSString* lp = [g_out stringByAppendingPathComponent:@"cdp.log"];
  [@"" writeToFile:lp atomically:YES encoding:NSUTF8StringEncoding error:nil];
  g_cdplog = [NSFileHandle fileHandleForWritingAtPath:lp];
  NSString* cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Spikes/s4"];
  [NSFileManager.defaultManager removeItemAtPath:cache error:nil];
  [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
  NSError* err = nil;
  if (![NCEngine startWithCachePath:cache error:&err]) { Say(@"ENGINE FAIL %@", err); exit(4); }
  CGFloat sh = NSScreen.screens.firstObject.frame.size.height;
  _win = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, sh - 100 - 640, 900, 640)
                                     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                       backing:NSBackingStoreBuffered defer:NO];
  _win.releasedWhenClosed = NO;
  _win.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
  g_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 640)];
  _win.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 640)];
  [_win.contentView addSubview:g_view];  // not the content view itself: CEF cannot finish closing a browser parented to it
  [_win makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)g_view, CefRect(0, 0, 900, 640));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserHost::CreateBrowserSync(info, new Client(), url.UTF8String, CefBrowserSettings(), nullptr, nullptr);
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ Checks(); });
  // Watchdog: leave nothing running if a check hangs.
  [NSTimer scheduledTimerWithTimeInterval:120 repeats:NO block:^(NSTimer*) {
    Say(@"WATCHDOG, closing");
    if (g_browser) g_browser->GetHost()->CloseBrowser(true); else exit(3);
  }];
}
- (void)tryToTerminateApplication:(id)sender { if (g_browser) g_browser->GetHost()->CloseBrowser(false); }
@end

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    NCApplication* app = (NCApplication*)NCApplication.sharedApplication;
    static S4Delegate* d = [S4Delegate new];
    app.delegate = d;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app run];
  }
  return 0;
}
