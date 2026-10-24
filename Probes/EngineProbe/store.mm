// Chrome Web Store checks (task B4). One launch = one case. The flow: apply the case's UA/brand override on the blank
// first page, navigate to the store listing through CDP, record the banner, the document request's Sec-CH-UA and the
// buttons, click "Add to Chrome" with CDP mouse input, accept Chrome's own install sheet in-process (accessibility press,
// then Return, then a click), wait for the extension on disk, wait for the post-install UI, and count windows and tabs.
// Hidden rule: nothing here shows or activates a window. macOS system dialogs are never touched; the sheet is a views
// dialog of this process and main.mm keeps it at alpha 0.
#import "store.h"
#import "store_rule.h"
#import <CoreGraphics/CoreGraphics.h>
#include <memory>
#include <string>
#include <unistd.h>

bool IsStoreCheck(NSString* check) {
  return [@[ @"store-stock", @"store-ua", @"store-brand", @"store-ua-brand", @"install-no-window" ] containsObject:check];
}

namespace {

using H = std::shared_ptr<const StoreHost>;
NSString* g_chk = nil;
NSString* g_mode = @"stock";   // stock | ua | brand | ua-brand
NSMutableDictionary* g_docs;   // requestId -> @{url, headers}: store document requests
NSString* g_ext_id = nil;
NSString* g_before = nil;      // window snapshot before the click
int g_main_before = 0, g_total_before = 0, g_tabs_before = -1, g_bw_before = 0;
NSMutableSet<NSNumber*>* g_known;  // window addresses present before the click (the dialog is any new one after it)
uintptr_t g_install_sheet = 0;     // address of the install confirmation sheet (compared, never dereferenced)
bool g_dialog_seen = false;

void Info(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void Info(NSString* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  printf("PROBE %s info %s\n", g_chk.UTF8String, s.UTF8String);
  fflush(stdout);
}

NSDictionary* Json(NSString* s) {
  id j = s.length ? [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
  return [j isKindOfClass:NSDictionary.class] ? j : nil;
}

void After(double sec, dispatch_block_t b) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), b);
}

// Polls |cond| every 250 ms for up to |ms|, then calls |done(bool)|.
void WaitFor(H h, int ms, std::function<bool()> cond, std::function<void(bool)> done) {
  if (h->done()) return;
  if (cond()) { done(true); return; }
  if (ms <= 0) { done(false); return; }
  After(0.25, ^{ WaitFor(h, ms - 250, cond, done); });
}

// What the store page shows. The banner is the deepest visible element that says "Switch to Chrome".
NSString* const kStateJS = @"(() => {"
  "const out = {url: location.href, ready: document.readyState, title: document.title, ua: navigator.userAgent, brands: 'none', banner: '', bannerCount: 0, buttons: []};"
  "try { if (navigator.userAgentData) out.brands = JSON.stringify(navigator.userAgentData.brands); } catch (e) {}"
  "const all = [];"
  "const walk = (root) => { for (const el of root.querySelectorAll('*')) { all.push(el); if (el.shadowRoot) walk(el.shadowRoot); } };"
  "walk(document);"
  "const txt = (el) => (el.innerText || el.textContent || '').trim().replace(/\\s+/g, ' ');"
  "const vis = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };"
  "for (const el of all) {"
  "  const t = txt(el);"
  "  if (t && t.length < 160 && /switch to chrome/i.test(t) && vis(el) && ![...el.children].some(c => /switch to chrome/i.test(txt(c)))) { out.bannerCount++; if (!out.banner) out.banner = t; }"
  "  if ((el.tagName === 'BUTTON' || el.getAttribute('role') === 'button') && t && t.length < 60 && out.buttons.length < 30 && vis(el)) {"
  "    const r = el.getBoundingClientRect();"
  "    out.buttons.push({t: t, dis: !!(el.disabled || el.getAttribute('aria-disabled') === 'true'), x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2)});"
  "  }"
  "}"
  "return JSON.stringify(out);"
  "})()";

void Click(const H& h, double x, double y) {
  for (NSString* type in @[ @"mouseMoved", @"mousePressed", @"mouseReleased" ])
    h->send(@"Input.dispatchMouseEvent",
            @{@"type" : type, @"x" : @(x), @"y" : @(y), @"button" : [type isEqual:@"mouseMoved"] ? @"none" : @"left", @"clickCount" : @1,
              @"buttons" : [type isEqual:@"mousePressed"] ? @1 : @0},
            [type](NSDictionary* r) { static int n = 0; if (n++ < 6) Info(@"Input.dispatchMouseEvent %@ reply %@", type, r[@"error"] ?: @"ok"); });
}

// Fallback when CDP mouse input does nothing: the page's own click() on the button with this text, run through CDP
// Runtime.evaluate with userGesture (the store's install call needs a user gesture; Chrome counts this one as one).
void JsClick(const H& h, NSString* pattern) {  // |pattern| holds no quotes or backslashes
  NSString* js = [NSString stringWithFormat:@"(() => { const re = new RegExp('%@', 'i'); const all = []; const walk = (r) => { for (const el of r.querySelectorAll('*')) { all.push(el); if (el.shadowRoot) walk(el.shadowRoot); } }; walk(document);"
                  "for (const el of all) { if ((el.tagName === 'BUTTON' || el.getAttribute('role') === 'button') && re.test((el.innerText || el.textContent || '').trim())) { el.click(); return 'clicked ' + el.tagName; } } return 'none'; })()", pattern];
  h->eval(js, false, [pattern](NSString* r) { Info(@"js click /%@/ -> %@", pattern, r); });
}

NSDictionary* FindButton(NSDictionary* st, NSString* pattern) {
  for (NSDictionary* b in st[@"buttons"])
    if ([b[@"t"] rangeOfString:pattern options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) return b;
  return nil;
}

NSString* ButtonList(NSDictionary* st) {
  NSMutableArray* a = [NSMutableArray array];
  for (NSDictionary* b in st[@"buttons"]) [a addObject:[NSString stringWithFormat:@"%@%@", b[@"t"], [b[@"dis"] boolValue] ? @"(disabled)" : @""]];
  return [a componentsJoinedByString:@" | "];
}

// Windows of this process: NSApp.windows, and CGWindowList with every window (alpha 0 and off screen ones included).
struct Snap { int total = 0, main = 0, cg = 0, browser = 0; NSString* text = @""; };
Snap Snapshot(const H& h) {
  Snap s;
  NSWindow* mainWin = h->window();
  NSString* mainClass = mainWin ? NSStringFromClass([mainWin class]) : @"";
  NSMutableArray* parts = [NSMutableArray array];
  for (NSWindow* w in NSApp.windows) {
    s.total++;
    if ([NSStringFromClass([w class]) isEqualToString:@"BrowserNativeWidgetWindow"]) s.browser++;
    if ([NSStringFromClass([w class]) isEqualToString:mainClass] && !w.isSheet && w.parentWindow == nil && w.sheetParent == nil) s.main++;
    [parts addObject:[NSString stringWithFormat:@"%@{vis=%d alpha=%.0f sheet=%d key=%d %.0fx%.0f}", NSStringFromClass([w class]), (int)w.isVisible, w.alphaValue, (int)w.isSheet, (int)w.isKeyWindow, w.frame.size.width, w.frame.size.height]];
  }
  CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
  for (NSDictionary* d in (__bridge NSArray*)list)
    if ([d[(id)kCGWindowOwnerPID] intValue] == getpid()) s.cg++;
  if (list) CFRelease(list);
  s.text = [NSString stringWithFormat:@"nsapp-windows=%d main-class(%@)=%d browser-windows=%d cg-windows=%d appActive=%d [%@]", s.total, mainClass, s.main, s.browser, s.cg, (int)NSApp.isActive, [parts componentsJoinedByString:@" "]];
  return s;
}

// Accessibility walk of a views dialog (old NSAccessibility informal protocol, which Chromium's nodes implement).
id AXAttr(id el, NSString* attr) {
  @try {
    if ([el respondsToSelector:@selector(accessibilityAttributeValue:)]) return [el accessibilityAttributeValue:attr];
  } @catch (...) {}
  return nil;
}
void AXWalk(id el, int depth, NSMutableArray* dump, NSMutableArray* buttons) {
  if (!el || depth > 14 || dump.count > 80) return;
  NSString* role = AXAttr(el, NSAccessibilityRoleAttribute);
  NSString* title = AXAttr(el, NSAccessibilityTitleAttribute);
  NSString* desc = AXAttr(el, NSAccessibilityDescriptionAttribute);
  if (![role isKindOfClass:NSString.class]) role = @"?";
  if (![title isKindOfClass:NSString.class]) title = @"";
  if (![desc isKindOfClass:NSString.class]) desc = @"";
  [dump addObject:[NSString stringWithFormat:@"%d:%@:'%@':'%@'", depth, role, title, desc]];
  if ([role isEqualToString:NSAccessibilityButtonRole]) [buttons addObject:@[ el, title.length ? title : desc ]];
  id ch = AXAttr(el, NSAccessibilityChildrenAttribute);
  if ([ch isKindOfClass:NSArray.class]) for (id c in ch) AXWalk(c, depth + 1, dump, buttons);
}

NSWindow* FindSheet() {
  for (NSWindow* w in NSApp.windows)
    if (w.isSheet || w.sheetParent) return w;
  return nil;
}
// The install confirmation sheet only. With P3 the post-install dialog is a second sheet on the same window; it must
// never be "accepted" by the install steps.
NSWindow* FindInstallSheet() {
  for (NSWindow* w in NSApp.windows)
    if ((uintptr_t)(__bridge void*)w == g_install_sheet && (w.isSheet || w.sheetParent)) return w;
  return nil;
}

void Key(NSWindow* w, NSEventType type) {
  NSEvent* e = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber
                                 context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
  [w sendEvent:e];
}

void MouseAt(NSWindow* w, NSPoint p, NSEventType type) {
  NSEvent* e = [NSEvent mouseEventWithType:type location:p modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:w.windowNumber
                                   context:nil eventNumber:0 clickCount:1 pressure:type == NSEventTypeLeftMouseDown ? 1 : 0];
  [w sendEvent:e];
}

// Accept the install sheet: accessibility press on "Add extension", else Return, else a click at the bottom right.
// Each method gets 3 s; returns through |done| once the sheet is gone (or after the last method).
void AcceptSheet(H h, int method, std::function<void()> done) {
  NSWindow* sheet = FindInstallSheet();
  if (!sheet || method > 2) { done(); return; }
  if (method == 0) {
    NSMutableArray* dump = [NSMutableArray array];
    NSMutableArray* buttons = [NSMutableArray array];
    AXWalk(sheet.contentView, 0, dump, buttons);
    if (!dump.count) AXWalk(sheet, 0, dump, buttons);
    Info(@"sheet ax-dump %@", [dump componentsJoinedByString:@" ; "]);
    id target = nil;
    for (NSArray* b in buttons)
      if ([b[1] rangeOfString:@"^(add extension|add)$" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) target = b[0];
    if (target) {
      @try { [target accessibilityPerformAction:NSAccessibilityPressAction]; Info(@"sheet accept method=ax-press performed"); } @catch (...) { Info(@"sheet accept method=ax-press threw"); }
    } else {
      Info(@"sheet accept method=ax-press no Add button found (buttons=%lu)", (unsigned long)buttons.count);
    }
  } else if (method == 1) {
    Key(sheet, NSEventTypeKeyDown);
    Key(sheet, NSEventTypeKeyUp);
    Info(@"sheet accept method=return-key sent");
  } else {
    NSSize s = sheet.frame.size;
    NSPoint p = NSMakePoint(s.width - 90, 30);  // the default (rightmost) button of a views dialog footer
    MouseAt(sheet, p, NSEventTypeLeftMouseDown);
    MouseAt(sheet, p, NSEventTypeLeftMouseUp);
    Info(@"sheet accept method=click at %.0f,%.0f of %.0fx%.0f", p.x, p.y, s.width, s.height);
  }
  After(3, ^{ if (FindInstallSheet()) AcceptSheet(h, method + 1, done); else done(); });
}

NSString* ExtensionsDir() {
  return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Noche Probe/Default/Extensions"];
}
NSString* InstalledId() {
  for (NSString* n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:ExtensionsDir() error:nil])
    if (n.length == 32) return n;
  return nil;
}

void Verdict2(H h, NSString* summary, bool ruleOk) {
  NSString* manifest = nil;
  NSString* vdir = [ExtensionsDir() stringByAppendingPathComponent:g_ext_id];
  NSString* ver = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:vdir error:nil] firstObject];
  NSData* md = ver ? [NSData dataWithContentsOfFile:[[vdir stringByAppendingPathComponent:ver] stringByAppendingPathComponent:@"manifest.json"]] : nil;
  NSDictionary* mj = md ? [NSJSONSerialization JSONObjectWithData:md options:0 error:nil] : nil;
  NSString* page = mj[@"options_ui"][@"page"] ?: mj[@"options_page"] ?: mj[@"action"][@"default_popup"];
  manifest = [NSString stringWithFormat:@"name=%@ version=%@ page=%@", mj[@"name"], mj[@"version"], page];
  Info(@"installed manifest %@", manifest);
  if (!page) { h->finish(false, [summary stringByAppendingString:@" no extension page to ask the service worker from"]); return; }
  h->send(@"Page.navigate", @{@"url" : [NSString stringWithFormat:@"chrome-extension://%@/%@", g_ext_id, page]}, [](NSDictionary*) {});
  After(5, ^{
    h->eval(@"(async () => { const r = {}; try { r.name = chrome.runtime.getManifest().name; } catch (e) { r.e1 = String(e); }"
            @"try { await chrome.runtime.sendMessage({what: 'noche-probe'}); } catch (e) { r.msg = String((e && e.message) || e); }"
            @"try { const c = await chrome.runtime.getContexts({contextTypes: ['BACKGROUND']}); r.bg = c.length; r.bgUrl = c[0] && c[0].documentUrl; } catch (e) { r.e2 = String(e); }"
            @"return JSON.stringify(r); })()", true, [=](NSString* s) {
      Info(@"extension service worker: %@", s);
      NSDictionary* j = Json(s);
      const bool swAlive = [j[@"bg"] intValue] >= 1;
      const bool ok = ruleOk && swAlive;
      h->finish(ok, [NSString stringWithFormat:@"%@ serviceWorkerAlive=%d", summary, (int)swAlive]);
    });
  });
}

// Final steps: the installed extension's service worker, then the verdict.
void Verdict(H h, bool installed, NSString* summary) {
  Snap after = Snapshot(h);
  int tabs = h->tabCount();
  Info(@"windows after: %@", after.text);
  Info(@"windows before: %@", g_before);
  Info(@"tabs before=%d after=%d; activate calls blocked=%d; appActive=%d", g_tabs_before, tabs, h->activateBlocked(), (int)NSApp.isActive);
  const bool sameTabs = g_tabs_before < 0 || tabs == g_tabs_before;
  if (NSApp.isActive) { h->finish(false, [summary stringByAppendingString:@" APP BECAME ACTIVE"]); return; }
  if (![g_chk isEqualToString:@"install-no-window"]) { h->finish(true, summary); return; }
  if (!installed) { h->finish(false, [summary stringByAppendingString:@" install did not complete"]); return; }
  // The pass rule (store_rule.h): no browser window at all, no guard hit on one, no new-tab/apps target, the
  // post-install dialog really showed, same tab count. Blocked activation attempts are printed as info only.
  h->send(@"Target.getTargets", @{}, [=](NSDictionary* r) {
    int stale = -1;
    NSArray* infos = r[@"result"][@"targetInfos"];
    if ([infos isKindOfClass:NSArray.class]) {
      stale = 0;
      for (NSDictionary* t in infos) {
        NSString* u = t[@"url"] ?: @"";
        Info(@"target type=%@ url=%@", t[@"type"], u.length > 100 ? [u substringToIndex:100] : u);
        if ([u hasPrefix:@"chrome://newtab"] || [u hasPrefix:@"chrome://new-tab-page"] || [u hasPrefix:@"chrome://apps"] || [u hasPrefix:@"chrome-untrusted://new-tab-page"]) stale++;
      }
    } else {
      Info(@"Target.getTargets unavailable on this session (%@): new-tab check falls back to the browser-window and tab-count rules", r[@"error"] ?: @"no result");
    }
    InstallFacts f;
    f.browserWindowsBefore = g_bw_before;
    f.browserWindowsAfter = after.browser;
    f.browserWindowOrders = h->browserWindowOrders();
    f.staleTabTargets = stale;
    f.dialogSeen = g_dialog_seen;
    f.sameTabs = sameTabs;
    std::string why;
    const bool ruleOk = InstallNoWindowOk(f, &why);
    Info(@"install-no-window facts: browserWindows %d -> %d, browser-window guard hits %d, stale targets %d, dialog seen %d, same tabs %d, activate calls blocked %d (info)",
         f.browserWindowsBefore, f.browserWindowsAfter, f.browserWindowOrders, f.staleTabTargets, (int)f.dialogSeen, (int)f.sameTabs, h->activateBlocked());
    if (!ruleOk) { h->finish(false, [NSString stringWithFormat:@"%@ RULE FAILED: %s", summary, why.c_str()]); return; }
    Verdict2(h, summary, ruleOk);
  });
}

void WatchDialog(H h, int left, dispatch_block_t done) {
  for (NSWindow* w in NSApp.windows) {
    if ([g_known containsObject:@((uintptr_t)(__bridge void*)w)] || (uintptr_t)(__bridge void*)w == g_install_sheet) continue;
    if ([NSStringFromClass([w class]) isEqualToString:@"NativeWidgetMacNSWindow"] && (w.isVisible || w.isSheet)) {
      if (!g_dialog_seen) Info(@"post-install dialog window seen: NativeWidgetMacNSWindow vis=%d sheet=%d %.0fx%.0f", (int)w.isVisible, (int)w.isSheet, w.frame.size.width, w.frame.size.height);
      g_dialog_seen = true;
    }
  }
  if (left <= 0) { done(); return; }
  After(0.25, ^{ WatchDialog(h, left - 1, done); });
}

void AfterInstallClick(H h, NSDictionary* st) {
  NSString* base = [NSString stringWithFormat:@"mode=%@ banner=%@ brands=%@", g_mode, [st[@"banner"] length] ? @"present" : @"absent", st[@"brands"]];
  WaitFor(h, 20000, [] { return FindSheet() != nil; }, [=](bool sheetUp) {
    if (!sheetUp) {
      Info(@"no install sheet appeared in 20 s; %@", ButtonList(st));
      h->eval(kStateJS, false, [=](NSString* s) {
        Info(@"state after click: %@", s);
        Verdict(h, false, [base stringByAppendingString:@" install=no-prompt"]);
      });
      return;
    }
    g_install_sheet = (uintptr_t)(__bridge void*)FindSheet();
    Snap withSheet = Snapshot(h);
    Info(@"sheet up: %@", withSheet.text);
    AcceptSheet(h, 0, [=] {
      if (FindInstallSheet()) { Verdict(h, false, [base stringByAppendingString:@" install=sheet-not-accepted"]); return; }
      WaitFor(h, 40000, [] { g_ext_id = InstalledId(); return g_ext_id != nil; }, [=](bool installed) {
        Info(@"install result: extension on disk=%d id=%@", (int)installed, g_ext_id ?: @"-");
        // The post-install UI (stray window, dialog) shows up within a moment: watch 6 s for a window that did not exist
        // before the click (the install sheet itself excluded), of the dialog's class (NativeWidgetMacNSWindow), visible or a sheet.
        WatchDialog(h, 24, ^{
          h->eval(kStateJS, false, [=](NSString* s) {
            NSDictionary* fin = Json(s);
            Info(@"state after install: buttons=%@", fin ? ButtonList(fin) : s);
            Verdict(h, installed, [base stringByAppendingFormat:@" install=%@", installed ? @"completed" : @"not-completed"]);
          });
        });
      });
    });
  });
}

void Settled(H h, NSDictionary* st) {
  Info(@"store state: url=%@ title=%@", st[@"url"], st[@"title"]);
  Info(@"store state: navigator.userAgent=%@", st[@"ua"]);
  Info(@"store state: navigator.userAgentData.brands=%@", st[@"brands"]);
  Info(@"store state: banner count=%@ text=%@", st[@"bannerCount"], [st[@"banner"] length] ? st[@"banner"] : @"(none)");
  Info(@"store state: buttons=%@", ButtonList(st));
  NSDictionary* add = FindButton(st, @"^add to ");
  if (!add) {
    Info(@"no Add to Chrome button on the page");
    Verdict(h, false, [NSString stringWithFormat:@"mode=%@ banner=%@ brands=%@ install=no-add-button", g_mode, [st[@"banner"] length] ? @"present" : @"absent", st[@"brands"]]);
    return;
  }
  Snap before = Snapshot(h);
  g_before = before.text; g_main_before = before.main; g_total_before = before.total; g_bw_before = before.browser; g_tabs_before = h->tabCount();
  Info(@"windows before click: %@ tabs=%d", before.text, g_tabs_before);
  g_known = [NSMutableSet set];
  for (NSWindow* w in NSApp.windows) [g_known addObject:@((uintptr_t)(__bridge void*)w)];
  Info(@"click %@ at %@,%@ (disabled=%@)", add[@"t"], add[@"x"], add[@"y"], add[@"dis"]);
  Click(h, [add[@"x"] doubleValue], [add[@"y"] doubleValue]);
  After(4, ^{ if (!FindSheet()) JsClick(h, @"^add to "); });  // CDP mouse input did nothing: the page's own click
  AfterInstallClick(h, st);
}

// Polls the page until the listing shows its buttons (handling a cookie consent page), then re-samples once after 3 s.
void PollPage(H h, int tries, int settledOnce) {
  if (h->done()) return;
  h->eval(kStateJS, false, [=](NSString* s) {
    NSDictionary* st = Json(s);
    NSString* url = st[@"url"] ?: @"";
    if (tries == 0 || tries % 10 == 0) Info(@"poll %d url=%@ ready=%@ buttons=%@", tries, url, st[@"ready"], st ? ButtonList(st) : @"-");
    if ([url containsString:@"consent."]) {
      NSDictionary* b = FindButton(st, @"^(reject all|accept all)");
      if (b && tries % 4 == 0) { Info(@"consent page: cdp click %@ at %@,%@", b[@"t"], b[@"x"], b[@"y"]); Click(h, [b[@"x"] doubleValue], [b[@"y"] doubleValue]); }
      if (b && tries % 4 == 2 && tries >= 6) JsClick(h, @"^reject all");
    }
    const bool onStore = [url hasPrefix:@"https://chromewebstore.google.com/"];
    const bool listed = onStore && [st[@"ready"] isEqualToString:@"complete"] && (FindButton(st, @"^(add to |remove from |switch to )") || [st[@"banner"] length]);
    if (listed && settledOnce) { Settled(h, st); return; }
    if (tries > 100) { h->finish(false, [NSString stringWithFormat:@"store page never settled (url=%@)", url]); return; }
    After(listed ? 3 : 1, ^{ PollPage(h, tries + 1, listed ? 1 : 0); });
  });
}

void Navigate(H h) {
  NSString* url = @(getenv("NOCHE_PROBE_STORE_URL") ?: "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh");
  Info(@"navigate %@", url);
  h->send(@"Page.navigate", @{@"url" : url}, [=](NSDictionary* r) { Info(@"Page.navigate reply %@", r[@"result"] ?: r[@"error"]); });
  After(2, ^{ PollPage(h, 0, 0); });
}

NSDictionary* Meta(bool brand) {
  NSArray* list = @[ @{@"brand" : @"Not-A.Brand", @"version" : @"24"}, @{@"brand" : @"Chromium", @"version" : @"156"}, @{@"brand" : @"Google Chrome", @"version" : @"156"} ];
  NSArray* full = @[ @{@"brand" : @"Not-A.Brand", @"version" : @"24.0.0.0"}, @{@"brand" : @"Chromium", @"version" : @"156.0.8078.48"}, @{@"brand" : @"Google Chrome", @"version" : @"156.0.8078.48"} ];
  (void)brand;
  return @{@"brands" : list, @"fullVersionList" : full, @"platform" : @"macOS", @"platformVersion" : @"15.0.0", @"architecture" : @"arm", @"model" : @"", @"mobile" : @NO, @"bitness" : @"64", @"wow64" : @NO};
}

void ApplyMode(H h) {
  if ([g_mode isEqualToString:@"stock"]) { Info(@"override: none (stock)"); Navigate(h); return; }
  h->eval(@"navigator.userAgent", false, [=](NSString* stock) {
    Info(@"stock navigator.userAgent=%@", stock);
    // ua: the UA string carries the full Chrome version and no client hints are sent. brand: stock string plus a
    // "Google Chrome" brand list. ua-brand: both.
    NSString* full = [stock stringByReplacingOccurrencesOfString:@"Chrome/156.0.0.0" withString:@"Chrome/156.0.8078.48"];
    const bool ua = [g_mode isEqualToString:@"ua"] || [g_mode isEqualToString:@"ua-brand"];
    const bool brand = [g_mode isEqualToString:@"brand"] || [g_mode isEqualToString:@"ua-brand"];
    NSMutableDictionary* p = [@{@"userAgent" : ua ? full : stock} mutableCopy];
    if (brand) p[@"userAgentMetadata"] = Meta(true);
    Info(@"override: userAgent=%@ metadata=%@", p[@"userAgent"], brand ? @"brands incl. Google Chrome" : @"none");
    h->send(@"Emulation.setUserAgentOverride", p, [=](NSDictionary* r) { Info(@"setUserAgentOverride reply %@", r[@"error"] ?: @"ok"); Navigate(h); });
  });
}

}  // namespace

bool RunStoreCheck(NSString* check, const StoreHost& host) {
  if (!IsStoreCheck(check)) return false;
  H h = std::make_shared<const StoreHost>(host);
  g_chk = check;
  g_docs = [NSMutableDictionary dictionary];
  g_mode = [check isEqualToString:@"install-no-window"] ? @(getenv("NOCHE_PROBE_STORE_MODE") ?: "stock") : [check substringFromIndex:6];
  h->ensureVisible([h](bool ok) {
    if (!ok) { h->finish(false, @"probe window never became a visible, inactive Widget"); return; }
    // Danger gate: the post-install path can call Show() on a Browser window, which ends in
    // [NSApp activateIgnoringOtherApps:YES]. No install without the guard that turns that into a no-op.
    if (!h->guardsInstalled()) { h->finish(false, @"activation guard not installed, refusing to install anything"); return; }
    Info(@"mode=%@ guards installed, appActive=%d", g_mode, (int)NSApp.isActive);
    h->setEventHook([h](NSDictionary* e) {
      NSString* m = e[@"method"];
      NSDictionary* p = e[@"params"];
      if ([m isEqualToString:@"Network.requestWillBeSent"] && [p[@"type"] isEqualToString:@"Document"]) {
        NSString* u = p[@"request"][@"url"];
        Info(@"requestWillBeSent Document %@ (requestId=%@)", [u length] > 140 ? [u substringToIndex:140] : u, p[@"requestId"]);
        if ([u hasPrefix:@"https://chromewebstore.google.com/"]) g_docs[p[@"requestId"]] = @{@"url" : u};
      } else if ([m isEqualToString:@"Network.requestWillBeSentExtraInfo"] && g_docs[p[@"requestId"]]) {
        // The headers as they go on the wire (requestWillBeSent only has the renderer's view).
        NSMutableArray* keep = [NSMutableArray array];
        for (NSString* k in p[@"headers"]) {
          NSString* l = k.lowercaseString;
          if ([l hasPrefix:@"sec-ch-"] || [l isEqualToString:@"user-agent"] || [l isEqualToString:@"sec-fetch-dest"]) [keep addObject:[NSString stringWithFormat:@"%@: %@", l, p[@"headers"][k]]];
        }
        [keep sortUsingSelector:@selector(compare:)];
        Info(@"store document request headers (requestId=%@): %@", p[@"requestId"], keep.count ? [keep componentsJoinedByString:@" || "] : @"(no sec-ch-* or user-agent header)");
      }
    });
    h->send(@"Network.enable", @{}, [](NSDictionary*) {});
    h->send(@"Page.enable", @{}, [](NSDictionary*) {});
    ApplyMode(h);
  });
  return true;
}
