// Spike S2: rounded Alloy browser card inset over an NSVisualEffectView sidebar.
// Throwaway code. Driven by a command file (--ctl <path>); results go to stderr as "[S2 <ms>] ...".
// Commands: "tab N", "resize W H MS", "scroll MS", "quit".
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "CefBridge.h"

static const CGFloat kSidebar = 197, kInset = 6, kRadius = 10;
static const CGFloat kW = 1100, kH = 700, kLeft = 100, kTop = 100;  // initial window frame, top-left screen coordinates

static double NowMs() { return NSProcessInfo.processInfo.systemUptime * 1000.0; }
static void Log(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  fprintf(stderr, "[S2 %.1f] %s\n", NowMs(), s.UTF8String);
  fflush(stderr);
}

@interface S2Window : NSWindow
@end
@implementation S2Window
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface S2Delegate : NSObject <NSApplicationDelegate>
@end

@implementation S2Delegate {
  S2Window* _win;
  NSView* _card;
  NSMutableArray<NCBrowserView*>* _tabs;
  int _closed;
  NSString* _ctl;
}

- (void)tryToTerminateApplication:(id)sender { [self quit]; }

- (void)quit {
  Log(@"quit requested");
  for (NCBrowserView* t in _tabs) [t close];
}

- (void)applicationDidFinishLaunching:(NSNotification*)n {
  NSArray<NSString*>* args = NSProcessInfo.processInfo.arguments;
  NSString* u0 = @"https://example.com";
  NSString* u1 = @"https://example.org";
  NSString* cache = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Spikes/s2"];
  for (NSUInteger i = 1; i + 1 < args.count; i++) {
    if ([args[i] isEqualToString:@"--ctl"]) _ctl = args[i + 1];
    else if ([args[i] isEqualToString:@"--url0"]) u0 = args[i + 1];
    else if ([args[i] isEqualToString:@"--url1"]) u1 = args[i + 1];
    else if ([args[i] isEqualToString:@"--cache"]) cache = args[i + 1];
  }
  [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
  NSError* err = nil;
  if (![NCEngine startWithCachePath:cache error:&err]) { Log(@"ENGINE FAIL %@", err); exit(4); }
  Log(@"ENGINE up");

  CGFloat screenH = NSScreen.screens.firstObject.frame.size.height;
  NSRect frame = NSMakeRect(kLeft, screenH - kTop - kH, kW, kH);
  _win = [[S2Window alloc] initWithContentRect:frame
                                     styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable |
                                               NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                       backing:NSBackingStoreBuffered defer:NO];
  _win.releasedWhenClosed = NO;
  _win.titlebarAppearsTransparent = YES;
  _win.titleVisibility = NSWindowTitleHidden;
  _win.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace;
  _win.opaque = NO;
  _win.backgroundColor = NSColor.clearColor;

  NSVisualEffectView* vev = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kW, kH)];
  vev.material = NSVisualEffectMaterialSidebar;
  vev.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  vev.state = NSVisualEffectStateActive;
  _win.contentView = vev;

  NSRect cb = vev.bounds;
  _card = [[NSView alloc] initWithFrame:NSMakeRect(kSidebar, kInset, cb.size.width - kSidebar - kInset, cb.size.height - 2 * kInset)];
  _card.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _card.wantsLayer = YES;
  _card.layer.cornerRadius = kRadius;
  _card.layer.masksToBounds = YES;
  _card.layer.borderWidth = 1;
  _card.layer.borderColor = [NSColor colorWithSRGBRed:0x2a / 255. green:0x2a / 255. blue:0x2a / 255. alpha:1].CGColor;
  // Dark card background so a not-yet-painted browser is not shown as black.
  _card.layer.backgroundColor = [NSColor colorWithSRGBRed:0.12 green:0.12 blue:0.12 alpha:1].CGColor;
  [vev addSubview:_card];

  _tabs = [NSMutableArray new];
  NSArray<NSString*>* urls = @[ u0, u1 ];
  for (NSUInteger i = 0; i < urls.count; i++) {
    NCBrowserView* v = [[NCBrowserView alloc] initWithFrame:_card.bounds url:urls[i]];
    v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    v.hidden = i != 0;
    int idx = (int)i;
    v.onLoadEnd = ^(NSInteger s) { Log(@"LOADEND tab=%d status=%ld", idx, (long)s); };
    v.onLoadError = ^(NSInteger c) { Log(@"LOADERROR tab=%d code=%ld", idx, (long)c); };
    v.onTitleChange = ^(NSString* t) { Log(@"TITLE tab=%d %@", idx, t); };
    __weak S2Delegate* ws = self;
    v.onClosed = ^{ [ws viewClosed]; };
    [_card addSubview:v];
    [_tabs addObject:v];
  }
  [_win makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  Log(@"WINDOW shown, frame top-left x=%.0f y=%.0f w=%.0f h=%.0f", _win.frame.origin.x,
      screenH - _win.frame.origin.y - _win.frame.size.height, _win.frame.size.width, _win.frame.size.height);

  [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:NO block:^(NSTimer*) {
    Log(@"WINDOW state visible=%d onActiveSpace=%d occluded=%d key=%d", self->_win.visible, self->_win.onActiveSpace,
        !(self->_win.occlusionState & NSWindowOcclusionStateVisible), self->_win.keyWindow);
  }];
  if (_ctl) [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (void)viewClosed {
  Log(@"browser closed (%d of %d)", _closed + 1, (int)_tabs.count);
  if (++_closed == (int)_tabs.count) {
    Log(@"all browsers closed, shutting down");
    dispatch_async(dispatch_get_main_queue(), ^{ [NCEngine shutdown]; exit(0); });
  }
}

- (void)poll {
  NSString* s = [NSString stringWithContentsOfFile:_ctl encoding:NSUTF8StringEncoding error:nil];
  if (!s.length) return;
  [NSFileManager.defaultManager removeItemAtPath:_ctl error:nil];
  for (NSString* line in [s componentsSeparatedByString:@"\n"]) {
    NSArray<NSString*>* p = [line componentsSeparatedByString:@" "];
    if (!p.count || !p[0].length) continue;
    Log(@"CMD %@", line);
    if ([p[0] isEqualToString:@"tab"] && p.count > 1) [self showTab:p[1].intValue];
    else if ([p[0] isEqualToString:@"resize"] && p.count > 3) [self resizeW:p[1].doubleValue h:p[2].doubleValue ms:p[3].doubleValue];
    else if ([p[0] isEqualToString:@"scroll"] && p.count > 1) [self scrollMs:p[1].doubleValue];
    else if ([p[0] isEqualToString:@"quit"]) [self quit];
  }
}

- (void)showTab:(int)i {
  for (NSUInteger k = 0; k < _tabs.count; k++) _tabs[k].hidden = (int)k != i;
  Log(@"TAB shown %d", i);
}

- (void)resizeW:(CGFloat)w h:(CGFloat)h ms:(double)ms {
  NSRect f0 = _win.frame;
  double t0 = NowMs();
  Log(@"RESIZE start from %.0fx%.0f to %.0fx%.0f over %.0f ms", f0.size.width, f0.size.height, w, h, ms);
  __block NSTimer* tm = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer* t) {
    double k = MIN(1.0, (NowMs() - t0) / ms);
    NSRect f = f0;
    f.size.width = f0.size.width + (w - f0.size.width) * k;
    f.size.height = f0.size.height + (h - f0.size.height) * k;
    f.origin.y = f0.origin.y + f0.size.height - f.size.height;  // keep the top-left fixed
    [self->_win setFrame:f display:YES];
    Log(@"RESIZE step %.0fx%.0f", f.size.width, f.size.height);
    if (k >= 1) { [t invalidate]; Log(@"RESIZE done"); }
  }];
}

// Wheel events are built with CGEvent and delivered through the window, not posted to the system.
- (void)scrollMs:(double)ms {
  double t0 = NowMs();
  Log(@"SCROLL start %.0f ms", ms);
  [NSTimer scheduledTimerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer* t) {
    if (NowMs() - t0 >= ms) { [t invalidate]; Log(@"SCROLL done"); return; }
    CGEventRef ev = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 1, -24);
    NSPoint wp = NSMakePoint(600, 350);
    NSPoint sp = [self->_win convertPointToScreen:wp];
    CGFloat sh = NSScreen.screens.firstObject.frame.size.height;
    CGEventSetLocation(ev, CGPointMake(sp.x, sh - sp.y));
    CGEventSetIntegerValueField(ev, (CGEventField)91, self->_win.windowNumber);  // window under pointer
    CGEventSetIntegerValueField(ev, (CGEventField)92, self->_win.windowNumber);  // window that can handle the event
    NSEvent* ne = [NSEvent eventWithCGEvent:ev];
    CFRelease(ev);
    NSView* target = [self->_win.contentView hitTest:[self->_win.contentView.superview convertPoint:wp fromView:nil]];
    static BOOL logged = NO;
    if (!logged && (logged = YES)) { Log(@"SCROLL target %@ window=%ld evwin=%ld", NSStringFromClass(target.class), (long)self->_win.windowNumber, (long)ne.windowNumber); }
    [target scrollWheel:ne];
  }];
}
@end

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    NCApplication* app = (NCApplication*)NCApplication.sharedApplication;
    static S2Delegate* d = [S2Delegate new];
    app.delegate = d;
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];
    [app run];
  }
  return 0;
}
