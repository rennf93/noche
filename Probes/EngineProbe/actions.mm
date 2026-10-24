// Extension action checks: see actions.h. Hidden rule: nothing here shows, activates or makes key any window. The
// popup is a Chrome bubble, shown inactive (Execute with activate=false, ExtensionPopup::ShowPopupAtRect: Widget::Show
// of a non-activatable widget is ShowInactive), and a 5 ms timer keeps its alpha at 0 like the probe's own window.
#import "actions.h"
#include <memory>
#include <string>
#include <vector>

#ifndef NOCHE_ACTIONS_API
bool RunActionsCheck(NSString* check, const ActionsHost& host) {
  static NSSet* names = [NSSet setWithObjects:@"actions-list", @"badge-observer", @"popup-anchor", @"popup-tabid", @"popup-closes", nil];
  if (![names containsObject:check]) return false;
  host.finish(false, @"built without NOCHE_ACTIONS_API (needs the B5 engine)");
  return true;
}
#else
#include "include/cef_extension_action.h"

namespace {

using H = std::shared_ptr<const ActionsHost>;
void Crumb(const char* what) { fprintf(stderr, "[PROBE] CRUMB %s\n", what); fflush(stderr); }
int g_added = 0, g_updated = 0;  // observer counters; counts only, never an action reference
int g_badge7 = 0;  // OnActionUpdated calls whose payload already carried badge "7" on 0xFFFF0000 (icon loads fire it too)
NSButton* g_button = nil;
id g_hide = nil;  // the NSNotificationCenter observer token

class Obs : public CefExtensionActionObserver {
 public:
  void OnActionAdded(CefRefPtr<CefExtensionAction>) override { g_added++; }
  void OnActionUpdated(CefRefPtr<CefExtensionAction> a) override {
    g_updated++;
    if (a && a->GetBadgeText(nullptr).ToString() == "7" && a->GetBadgeBackgroundColor(nullptr) == 0xFFFF0000) g_badge7++;
  }
 private:
  IMPLEMENT_REFCOUNTING(Obs);
};

void Done(const H& h, bool ok, NSString* detail) {
  if (g_hide) [NSNotificationCenter.defaultCenter removeObserver:g_hide];
  g_hide = nil;
  g_button = nil;
  h->finish(ok, detail);
}

// |h| is by value: the dispatch block below must copy it. A block that captures a reference parameter keeps the
// reference, which dangled after the caller returned (SEGV in WaitFor, found in the B5 run).
void WaitFor(H h, int timeoutMs, std::function<bool()> cond, std::function<void(bool)> done) {
  if (h->done()) return;
  if (cond()) { done(true); return; }
  if (timeoutMs <= 0) { done(false); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(),
                 ^{ WaitFor(h, timeoutMs - 100, cond, done); });
}

// The probe extension's action, or NULL until Chrome has loaded the extension.
CefRefPtr<CefExtensionAction> Find(const H& h) {
  auto v = h->view();
  if (!v) return nullptr;
  std::vector<CefRefPtr<CefExtensionAction>> all;
  v->GetExtensionActions(all);
  for (auto& a : all)
    if (a->GetName().ToString().find("Noche engine probe extension") != std::string::npos) return a;
  return nullptr;
}

// Opaque pixels of the icon, and how many of them are the fixture icon's color #3366cc (RGBA, 3 per channel of slack).
int NonTransparentPixels(CefRefPtr<CefImage> img, int* w, int* hgt, int* fixtureColor) {
  *fixtureColor = 0;
  if (!img) return 0;
  CefRefPtr<CefBinaryValue> bin = img->GetAsBitmap(2.0f, CEF_COLOR_TYPE_RGBA_8888, CEF_ALPHA_TYPE_PREMULTIPLIED, *w, *hgt);
  if (!bin) return 0;
  std::vector<uint8_t> px(bin->GetSize());
  bin->GetData(px.data(), px.size(), 0);
  int n = 0;
  for (size_t i = 0; i + 3 < px.size(); i += 4) {
    if (px[i + 3]) n++;
    if (px[i + 3] == 255 && abs(px[i] - 0x33) <= 3 && abs(px[i + 1] - 0x66) <= 3 && abs(px[i + 2] - 0xcc) <= 3) (*fixtureColor)++;
  }
  return n;
}

// Zeroes the alpha of every child window of the probe window (the popup bubble) on each window update, which runs
// before the window is displayed, so nothing shows on the owner's screen. Window ordering is not a notification.
void KeepChildrenInvisible(NSWindow* w) {
  g_hide = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidUpdateNotification object:nil queue:nil usingBlock:^(NSNotification*) {
    for (NSWindow* c in w.childWindows) if (c.alphaValue != 0) c.alphaValue = 0;
  }];
}

// An NSButton in the probe window and its rectangle as Execute() wants it (DIP, origin top left of the primary
// display), plus the same rect in AppKit screen coordinates (origin bottom left) for the frame check.
CefRect ButtonRect(NSWindow* w, NSRect* appkit) {
  if (!g_button) {
    g_button = [NSButton buttonWithTitle:@"actions" target:nil action:nil];
    g_button.frame = NSMakeRect(20, w.contentView.bounds.size.height - 60, 90, 24);
    [w.contentView addSubview:g_button];
  }
  NSRect s = [w convertRectToScreen:[g_button convertRect:g_button.bounds toView:nil]];
  *appkit = s;
  CGFloat primaryH = NSScreen.screens.firstObject.frame.size.height;
  return CefRect((int)lround(s.origin.x), (int)lround(primaryH - NSMaxY(s)), (int)lround(s.size.width), (int)lround(s.size.height));
}

// Runs the action as a click on the button, inactive, and waits until the popup NSWindow is up.
void OpenPopup(const H& h, std::function<void(NSString* err, NSRect button, NSWindow* popup)> cb) {
  NSWindow* w = h->window();
  KeepChildrenInvisible(w);
  NSRect btn;
  CefRect r = ButtonRect(w, &btn);
  auto a = Find(h);
  Crumb("popup: Execute");
  if (!a || !a->Execute(r, /*activate=*/false)) { cb(@"Execute returned false (action missing or disabled)", btn, nil); return; }
  WaitFor(h, 10000, [h, w] { auto a = Find(h); return a && a->IsShowingPopup() && w.childWindows.count && w.childWindows.lastObject.isVisible; },
          [h, w, cb, btn](bool up) { cb(up ? nil : @"popup window did not appear in 10s", btn, up ? w.childWindows.lastObject : nil); });
}

// The popup's content area in AppKit screen coordinates: the web contents view inside the bubble. The NSWindow frame is
// bigger (bubble_border.cc:351-353 expands the contents by the shadow insets). NSZeroRect if no such view was found.
NSView* FindView(NSView* v, NSString* part) {
  if ([NSStringFromClass(v.class) containsString:part]) return v;
  for (NSView* c in v.subviews) if (NSView* f = FindView(c, part)) return f;
  return nil;
}
NSRect ContentRect(NSWindow* popup, NSString** which) {
  for (NSString* part in @[ @"WebContentsViewCocoa", @"RenderWidgetHostViewCocoa" ]) {
    if (NSView* v = FindView(popup.contentView, part)) {
      *which = part;
      return [popup convertRectToScreen:[v convertRect:v.bounds toView:nil]];
    }
  }
  *which = @"none";
  return NSZeroRect;
}

// "Inactive" proof for the hidden rule: the app never became active and no window of ours is key.
NSString* ActivationProblem(NSWindow* w, NSWindow* popup) {
  if (NSApp.isActive) return @"application is active";
  if (w.isKeyWindow || popup.isKeyWindow || NSApp.keyWindow) return @"a window became key";
  return nil;
}

// Makes sure there are two tabs and the second is active. Ids only.
void TwoTabsSecondActive(const H& h, std::function<void(NSString* err)> cb) {
  auto v = h->view();
  if (v->GetTabCount() < 2 && !v->AddTab(h->url().UTF8String, nullptr, CefBrowserSettings(), nullptr, /*activate=*/false)) { cb(@"AddTab failed"); return; }
  WaitFor(h, 5000, [h] { return h->view()->GetTabCount() >= 2; }, [h, cb](bool two) {
    if (!two) { cb(@"second tab did not appear"); return; }
    std::vector<CefRefPtr<CefBrowser>> tabs;
    h->view()->GetTabs(tabs);
    const int second = tabs[1]->GetIdentifier();
    h->view()->SetActiveTab(tabs[1]);
    WaitFor(h, 5000, [h, second] { auto t = h->view()->GetActiveTab(); return t && t->GetIdentifier() == second; },
            [cb](bool ok) { cb(ok ? nil : @"second tab did not become active"); });
  });
}

void ActionsList(const H& h) {
  // The icon can load after the action is listed: wait for non-transparent pixels.
  auto detail = std::make_shared<NSString*>(@"");
  WaitFor(h, 10000, [h, detail] {
    Crumb("list: Find");
    auto a = Find(h);
    if (!a) return false;
    int pw = 0, ph = 0;
    Crumb("list: GetIcon");
    auto icon = a->GetIcon(nullptr, 16);
    Crumb(icon ? "list: got icon" : "list: icon NULL");
    int match = 0;
    int n = NonTransparentPixels(icon, &pw, &ph, &match);
    Crumb("list: pixels counted");
    *detail = [NSString stringWithFormat:@"id=%s name=%s title=\"%s\" enabled=%d pinned=%d icon=%dx%d px with alpha=%d, of them #3366cc=%d", a->GetId().ToString().c_str(), a->GetName().ToString().c_str(), a->GetTitle(nullptr).ToString().c_str(), (int)a->IsEnabled(nullptr), (int)a->IsPinned(), pw, ph, n, match];
    return n > 0 && match * 2 > n && a->GetTitle(nullptr).ToString() == "Noche probe action";
  }, [h, detail](bool ok) { Done(h, ok, ok ? *detail : [@"title or icon never became right: " stringByAppendingString:*detail]); });
}

void BadgeObserver(const H& h) {
  const int before = g_badge7;
  h->extCmd(@{@"what" : @"badge", @"text" : @"7", @"color" : @"#FF0000"}, [h, before](NSDictionary* r) {
    if (r[@"error"]) { Done(h, false, [NSString stringWithFormat:@"%@", r[@"error"]]); return; }
    auto got = std::make_shared<NSString*>(@"");
    WaitFor(h, 10000, [h, before, got] {
      auto a = Find(h);
      if (!a) return false;
      *got = [NSString stringWithFormat:@"text=\"%s\" textColor=0x%08x background=0x%08x OnActionUpdated=%d (with badge 7 on red: %d, before %d) OnActionAdded=%d", a->GetBadgeText(nullptr).ToString().c_str(), a->GetBadgeTextColor(nullptr), a->GetBadgeBackgroundColor(nullptr), g_updated, g_badge7, before, g_added];
      return a->GetBadgeText(nullptr).ToString() == "7" && a->GetBadgeBackgroundColor(nullptr) == 0xFFFF0000 && g_badge7 > before;
    }, [h, got](bool ok) { Done(h, ok, ok ? *got : [@"observer or API did not report the badge: " stringByAppendingString:*got]); });
  });
}

// Reads what the popup reported to the service worker: its resolved tabId and the CDP click count.
void PopupState(const H& h, std::function<bool(NSDictionary*)> ready, int timeoutMs, std::function<void(NSDictionary*)> cb) {
  auto last = std::make_shared<NSDictionary*>(nil);
  auto step = std::make_shared<std::function<void(int)>>();
  *step = [h, ready, last, step, cb](int left) {
    if (h->done()) { *step = nullptr; return; }
    h->extCmd(@{@"what" : @"popupTab"}, [=](NSDictionary* r) {
      *last = r;
      if (ready(r) || left <= 0) { auto f = cb; auto l = *last; *step = nullptr; f(l); return; }
      auto again = step;  // a block inside a temporary closure would capture the closure, not the shared_ptr
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{ (*again)(left - 200); });
    });
  };
  (*step)(timeoutMs);
}

void PopupAnchor(const H& h) {
  OpenPopup(h, [h](NSString* err, NSRect btn, NSWindow* popup) {
    if (err) { Done(h, false, err); return; }
    const NSRect f = popup.frame;
    NSString* which = nil;
    const NSRect content = ContentRect(popup, &which);
    // Content top vs button bottom (AppKit y is up); the frame top sits above it by the shadow inset.
    const double delta = NSIsEmptyRect(content) ? 1e9 : fabs(NSMaxY(content) - btn.origin.y);
    NSString* act = ActivationProblem(h->window(), popup);
    h->extCmd(@{@"what" : @"popupclick"}, [=](NSDictionary* r) {
      if (r[@"error"]) { Done(h, false, [NSString stringWithFormat:@"CDP click failed: %@ (content top %.1f via %@, frame top %.1f, button bottom %.1f)", r[@"error"], NSMaxY(content), which, NSMaxY(f), btn.origin.y]); return; }
      PopupState(h, ^bool(NSDictionary* s) { return [s[@"clicks"] intValue] >= 1; }, 10000, [=](NSDictionary* s) {
        const int clicks = [s[@"clicks"] intValue];
        NSString* act2 = act ?: ActivationProblem(h->window(), popup);
        Done(h, delta <= 2.0 && clicks >= 1 && !act2,
             [NSString stringWithFormat:@"popup content top %.1f (view %@; frame top %.1f incl. shadow) vs button bottom %.1f (delta %.1f pt, limit 2), CDP click reached popup.js %d time(s), tabId=%@, activation problem: %@", NSMaxY(content), which, NSMaxY(f), btn.origin.y, delta, clicks, s[@"tabId"], act2 ?: @"none"]);
      });
    });
  });
}

void PopupTabId(const H& h) {
  TwoTabsSecondActive(h, [h](NSString* err) {
    if (err) { Done(h, false, err); return; }
    h->extCmd(@{@"what" : @"tabs"}, [h](NSDictionary* t) {
      OpenPopup(h, [h, t](NSString* err, NSRect, NSWindow* popup) {
        if (err) { Done(h, false, err); return; }
        PopupState(h, ^bool(NSDictionary* s) { return s[@"tabId"] && s[@"tabId"] != NSNull.null; }, 10000, [h, t, popup](NSDictionary* s) {
          NSNumber* tab = s[@"tabId"];
          NSNumber* active = t[@"activeId"];
          NSNumber* first = [t[@"ids"] firstObject];
          const bool ok = [tab isKindOfClass:NSNumber.class] && [tab isEqual:active] && ![tab isEqual:first];
          Done(h, ok, [NSString stringWithFormat:@"popup resolved tabId=%@, active tab (chrome.tabs) id=%@, first tab id=%@ (must differ), activation problem: %@", tab, active, first, ActivationProblem(h->window(), popup) ?: @"none"]);
        });
      });
    });
  });
}

void PopupCloses(const H& h) {
  TwoTabsSecondActive(h, [h](NSString* err) {
    if (err) { Done(h, false, err); return; }
    OpenPopup(h, [h](NSString* err, NSRect, NSWindow*) {
      if (err) { Done(h, false, err); return; }
      NSWindow* w = h->window();
      H hh = h;  // local copy for the block (see WaitFor)
      // Control: the popup must survive a second with no tab change, or "closed" below proves nothing.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        const H& h = hh;
        auto a = Find(h);
        if (!a || !a->IsShowingPopup() || w.childWindows.count == 0) { Done(h, false, @"control failed: the popup closed by itself within 1 s, before any tab change"); return; }
        std::vector<CefRefPtr<CefBrowser>> tabs;
        h->view()->GetTabs(tabs);
        h->view()->SetActiveTab(tabs[0]);
        WaitFor(h, 5000, [h, w] { auto a = Find(h); return a && !a->IsShowingPopup() && w.childWindows.count == 0; }, [h](bool closed) {
          Done(h, closed, closed ? @"popup stayed open for 1 s (control), then closed after SetActiveTab to another tab" : @"popup still showing 5s after SetActiveTab");
        });
      });
    });
  });
}

}  // namespace

bool RunActionsCheck(NSString* check, const ActionsHost& host) {
  static NSSet* names = [NSSet setWithObjects:@"actions-list", @"badge-observer", @"popup-anchor", @"popup-tabid", @"popup-closes", nil];
  if (![names containsObject:check]) return false;
  H h = std::make_shared<const ActionsHost>(host);
  // The observer must exist before the extension loads; adding it also needs the first browser, which exists here.
  h->view()->AddExtensionActionObserver(new Obs());
  WaitFor(h, 20000, [h] { return Find(h) != nullptr; }, [h, check](bool found) {
    if (!found) { Done(h, false, @"the probe extension's action never appeared in GetExtensionActions (20s)"); return; }
    if ([check isEqualToString:@"actions-list"]) ActionsList(h);
    else if ([check isEqualToString:@"badge-observer"]) BadgeObserver(h);
    else if ([check isEqualToString:@"popup-anchor"]) PopupAnchor(h);
    else if ([check isEqualToString:@"popup-tabid"]) PopupTabId(h);
    else PopupCloses(h);
  });
  return true;
}
#endif
