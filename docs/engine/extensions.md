# Extension architecture from the CEF source

Status: research, read-only. Basis for the engine patch series (part B).
Source read: Chromium 156.0.8078.48 plus CEF commit 426920c. The effective source is Chromium plus `cef/patch/patches/*.patch`. The live tree was CEF-patched in place after most of the reading, so every Chromium line number below is of the UNPATCHED file unless marked "patched"; patched-file numbers come from the hunk headers of the CEF patch or from the live tree and are marked.

Citation conventions:
- `chrome/...`, `extensions/...`, `components/...`, `ui/...` are relative to chromium/src, line numbers are of the UNPATCHED file. Where CEF changes the file, the patch is cited too (`patch:<name>.patch`).
- `cef/...` is relative to the CEF checkout (`chromium/src/cef`, identical to `chromium_git/cef` at 426920c).
- Chromium files that CEF patches, and the patch: `browser.cc`, `browser_tabstrip.cc`, `browser_navigator.cc`, `window_feature_controller.cc` (all `chrome_browser_browser.patch`), `browser_view.cc` and `browser_widget.cc` (`chrome_runtime_views.patch`), `extension_tab_util.cc` and `tabs_api.cc` (`chrome_browser_extensions.patch`), `user_agent_utils.cc` (`embedder_product_override.patch`). `extension_install_ui_desktop.cc`, `extension_popup.cc`, `extension_action_view_model.cc`, `toolbar_actions_model.cc` and `extension_action_api.cc` are not patched by CEF.
- "unverified" means best-supported by the source but not settled; each has a named experiment in the last section.

Problem statement (M0, `docs/spikes/s1-chrome-style.md`): CEF allows one Chrome-style browser view per window (C4), `chrome.tabs.query` sees only the Chrome-style tab (C4b), there is no CEF API for extension toolbar actions (C5), and installing from the Web Store needed a UA brand override and opened a stray Chrome window (C2).

## Summary of the design

- Recommended tab architecture: one Chrome-style Browser per Noche window that holds all tabs in its `TabStripModel` (tab strip UI absent because a `TYPE_POPUP` Browser does not support `kFeatureTabStrip`, which `BrowserView::ShouldDrawTabStrip` checks before `GetTabStripVisible`, `browser_view.cc:1466-1471` and :1405 in the live tree), and the app picks the visible tab. Main risk: CEF assumes one CefBrowser per CefBrowserView, so the second and later tabs need a new ownership path.
- Extension actions: reuse Chromium's toolkit-neutral `ToolbarActionsModel` + `ExtensionActionViewModel`, expose them through a small CEF API, and show the popup with `ExtensionPopup` anchored to a screen rect.
- Install: redirect the post-install UI to the originating Browser instead of `FindOrCreateVisibleBrowser`, and add the brand entry before the first request.

## Q1. Where "Cannot add multiple Chrome style BrowserViews" is raised, and the one-per-window Chrome object

Raised at `cef/libcef/browser/views/browser_view_impl.cc:323-325` in `CefBrowserViewImpl::AddedToWidget()` (starts at :309):

```
if (!browser_ && !is_alloy_style_) {
  if (cef_widget->IsAlloyStyle()) { LOG(ERROR) << "Cannot add Chrome style BrowserView to Alloy style Window"; return; }   // :318-320
  if (cef_widget->IsChromeStyle() && cef_widget->GetThemeProfile()) { LOG(ERROR) << "Cannot add multiple Chrome style BrowserViews"; return; }   // :323-326
}
```

The guard is "this Widget already has an associated Profile". The first Chrome-style view registers its Profile at `browser_view_impl.cc:345` (`cef_widget_->AddAssociatedProfile(profile_)`); `ChromeBrowserWidget::GetThemeProfile()` (`cef/libcef/browser/chrome/views/chrome_browser_widget.cc:143`) then returns non-null for the second view. This is a proxy check, the real constraint is structural:

- A Chrome-style `CefWindow` creates a `ChromeBrowserWidget` (`cef/libcef/browser/views/widget.cc:33-37`, `CefWidget::Create`), which extends Chrome's `BrowserWidget`.
- A Chrome-style `CefBrowserView` creates a `ChromeBrowserView` (`browser_view_impl.cc:416-418`, `CreateRootView`), which extends Chrome's `BrowserView`.
- `ChromeBrowserHostImpl::CreateBrowser` (`cef/libcef/browser/chrome/chrome_browser_host_impl.cc:404-475`) builds ONE `Browser` around that view: it forces `TYPE_POPUP` and `is_trusted_source` (:427-430), passes the existing view as `chrome_params.window` (:437), and calls `chrome_browser_view->InitBrowser(browser)` (:460).
- The ownership model is documented in `cef/libcef/browser/chrome/views/chrome_browser_widget.h:19-90`: Browser owns its `BrowserWindow` (BrowserView), BrowserView and BrowserWidget own each other, and `chrome/browser/ui/browser.cc:286-314` takes the `window_` from `BrowserWindowCreateParams::window` (the unpatched file has `CHECK_IS_TEST()` for a custom window; CEF removes it in `chrome_browser_browser.patch`, hunk `@@ -306,9 +310,6`, so unpatched `browser.cc` alone would refuse this).

So the one-per-window Chrome object is the **`Browser`/`BrowserView`/`BrowserWidget` triple**: one Widget holds one BrowserView which is bound to one Browser. A `Browser` can hold many tabs (Q2), so the limit is on windows and views, not on tabs.

## Q2. Mapping to Browser, BrowserView and TabStripModel; many tabs in one view; entry points that add a tab

Mapping (Chrome style, Views-hosted):

| CEF object | Chrome object | Cite |
|---|---|---|
| `CefWindow` | `ChromeBrowserWidget` (a `BrowserWidget`) | `cef/libcef/browser/views/widget.cc:33-37` |
| `CefBrowserView` | `ChromeBrowserView` (a `BrowserView`) | `browser_view_impl.cc:416-418` |
| `CefBrowser` (`ChromeBrowserHostImpl`) | one per `WebContents`, pointing at a `Browser*` via `SetBrowser` | `chrome_browser_host_impl.cc:531-548` |
| none | `Browser` + `TabStripModel` | `chrome_browser_host_impl.cc:131` (`browser->tab_strip_model()->AddWebContents`) |

How the active tab becomes visible: `BrowserView` observes the `TabStripModel` and swaps the active `WebContents` into its `MultiContentsView` (`chrome/browser/ui/views/frame/browser_view.cc`, patched by `chrome_runtime_views.patch`: `OnActiveTabChanged` at :2034 and `OnTabStripModelChanged` at :3621 patched, :1974 and :3558 unpatched). CEF reads that view through `CefBrowserViewImpl::web_view()` (`browser_view_impl.cc:432-446`, `GetActiveContentsWebView`). The host side currently assumes the opposite for Views-hosted Browsers: `ChromeBrowserHostImpl::GetBrowserForBrowser` (`chrome_browser_host_impl.cc:99-110`) carries the comment "Views-hosted Browsers will contain a single ChromeBrowserHostImpl. Otherwise, there will be a ChromeBrowserHostImpl per Tab/WebContents" and resolves the host from the Browser's ACTIVE contents (`GetTabStripModel()->GetActiveWebContents()`). That is the invariant the main risk below rests on. What already works per tab is closing by index (`GetCurrentTabIndex` :603, `DoCloseBrowser` :589) and the per-WebContents lookup `GetBrowserForContents` (:87-90), which is also why S4 (DevTools protocol per tab) keeps working: each tab gets its own `ChromeBrowserHostImpl`, so `SendDevToolsMessage` addresses that tab's WebContents.

**Can one Chrome-style view hold many tabs with the app choosing the visible one? Yes in Chromium, no in CEF as shipped.** Three blockers, all verified in source:

1. Chromium refuses to add a second tab to this Browser. `NEW_FOREGROUND_TAB`/`NEW_BACKGROUND_TAB` goes through `WindowCanOpenTabs` (`chrome/browser/ui/navigator/browser_navigator.cc:121-137`), which is true only if the window supports `kFeatureTabStrip` or its tab strip is empty. Popup-type windows never support it (`chrome/browser/ui/window_feature_controller/window_feature_controller.cc`, `PopupBrowserSupportsWindowFeature` at :93-103 unpatched and :107-118 patched; dispatch at :172 unpatched). CEF hooks `SupportsWindowFeature` through `cef_delegate()->SupportsWindowFeature` (`chrome_browser_browser.patch`, hunk in `window_feature_controller.cc`; live :50-58) but NOT `CanSupportWindowFeature` (:67-69), and `WindowCanOpenTabs` calls the latter, so the navigator edit in P1 is still required, and CEF forces the type to `TYPE_POPUP` (`chrome_browser_host_impl.cc:428`). When it fails, `GetBrowserAndTabForDisposition` (`browser_navigator.cc:298-310`) calls `GetOrCreateBrowser` (:144-157), which calls `ProfileBrowserCollection::FindTabbedBrowser` (`chrome/browser/ui/browser_window/internal/profile_browser_collection.cc:27-50`, `TYPE_NORMAL` only) and otherwise creates a brand-new normal Chrome window. This is the stray window S1 saw. CEF does not patch this function (`patch:chrome_browser_browser.patch` only touches `browser_navigator.cc` for PiP and `CreateTargetContents`).
2. CEF creates a second `CefBrowser` for a new tab with the same Views platform delegate. `ChromeBrowserDelegate::SetAsDelegate` (`cef/libcef/browser/chrome/chrome_browser_delegate.cc:234-275`) builds `CefBrowserPlatformDelegate::Create(create_params_)` with the retained `browser_view`, and `CefBrowserViewImpl::BrowserCreated` (`browser_view_impl.cc:185-190`) simply overwrites `browser_`. The one-view-one-browser assumption is baked into `GetBrowser()` (`cef/include/views/cef_browser_view.h:81`) and `BrowserDestroyed` (`browser_view_impl.cc:192-199`, `DCHECK_EQ(browser, browser_)`).
3. No CEF API names "the tab to show". Existing partial hook: `ChromeBrowserHostImpl::OnSetFocus` calls `chrome::SelectNumberedTab(browser_, tab_index)` (`chrome_browser_host_impl.cc:152-171`), so `CefBrowserHost::SetFocus(true)` on a tab already activates it in its Browser, which is a usable stop-gap for `SelectTab`.

Existing CEF/Chromium entry points that create or add a tab (and what each does today in a Views-hosted Chrome-style Browser):

| Entry point | Path | Result today |
|---|---|---|
| Popup / `target=_blank` / `window.open`, `OnBeforePopup` handled | `CefBrowserInfoManager::CanCreateWindow` (`cef/libcef/browser/browser_info_manager.cc:112-239`) then `ChromeBrowserDelegate::AddWebContents` (`chrome_browser_delegate.cc:203-221`) -> `ChromeBrowserHostImpl::AddNewContents` (`chrome_browser_host_impl.cc:114-137`, `DCHECK(!browser_)`) | A new `Browser` and (with `popup_with_views_hosted_opener`, `browser_info_manager.cc:225,549-563`) a new Views window. Never a tab in the opener's Browser. |
| Same, `OnBeforePopup` unhandled | `use_default_browser_creation = true` (`browser_info_manager.cc:222`); `AddWebContents` returns false (:342-359); falls through to `chrome::AddWebContents` (`AddWebContents` in `chrome/browser/ui/browser_tabstrip.cc` (:98 unpatched; CEF hook from `chrome_browser_browser.patch`)) and the navigator | Blocker 1: a separate normal Chrome window. |
| `chrome.tabs.create` | `TabsCreateFunction::Run` (`chrome/browser/extensions/api/tabs/tabs_api.cc:2132`), window defaults to current, `OpenTabHelper::OpenTab` (`chrome/browser/extensions/open_tab_helper.cc:156-200`, `NEW_FOREGROUND_TAB` at :196) | Same navigator path, blocker 1. |
| Chrome commands (`IDC_NEW_TAB`) | `CefBrowserHost::ExecuteChromeCommand` (`chrome_browser_host_impl.cc:331-345`) or `CefCommandHandler::OnChromeCommand` to intercept (`cef/libcef/browser/chrome/chrome_browser_delegate.cc:93-111`) -> `chrome::AddAndReturnTabAt` (`browser_tabstrip.cc:44`) | Same navigator path, blocker 1. |
| `CefBrowserView::CreateBrowserView` | new view, new window | Q1 refusal if put in the same window. |

Once blocker 1 is lifted, a new tab created through `CreateTargetContents` already notifies CEF: `BrowserWindowFeatures::OnWebContentsCreated` (added by `patch:chrome_browser_browser.patch`, hunk "BrowserWindowFeatures::OnWebContentsCreated") calls `ChromeBrowserDelegate::OnWebContentsCreated` (`chrome_browser_delegate.cc:224-232`) which runs `SetAsDelegate` and creates the per-tab `ChromeBrowserHostImpl`. So only blocker 2 needs new code on the CEF side.

## Q3. What `chrome.tabs.query` enumerates and why S1's Alloy tabs were invisible

`TabsQueryFunction::Run` (`chrome/browser/extensions/api/tabs/tabs_api.cc:1841`) builds the list in `BuildTabList` (:1902-1940): it iterates `GetAllBrowserWindowInterfaces()` (`chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h:23`, impl `browser_window_interface_iterator_non_android.cc:9`), filters with `MatchesWindow` (:1942-1996: profile, `BrowserExtensionWindowController::From`, `IsVisibleToTabsAPIForExtension` at `chrome/browser/extensions/browser_extension_window_controller.cc:183`, window id and type), then walks `TabListInterface::From(browser)` for each (:1920-1937) and filters with `MatchesTab`. So the universe is "tabs in a `Browser`'s `TabStripModel`".

An Alloy-style `WebContents` is never inserted into any `Browser`/`TabStripModel`, so it is not in that universe. CEF added exactly one hole, in `patch:chrome_browser_extensions.patch` (hunk `ExtensionTabUtil::GetTabById`, issue 3681): `cef::GetAlloyTabById` (`cef/libcef/browser/chrome/extensions/chrome_extension_util.cc:14-62`) is consulted inside `ExtensionTabUtil::GetTabById` (`chrome/browser/extensions/extension_tab_util.cc`, function at :618, hook inserted at :672 unpatched and :677 patched, hunk `@@ -672,6 +677,14` of `chrome_browser_extensions.patch`; loop over `WindowControllerList` at :649), and `TabsUpdateFunction` was made to tolerate a null window (same patch, `tabs_api.cc` hunk). So id-addressed calls (`tabs.get`, `tabs.update`, probably `tabs.sendMessage`) can reach Alloy tabs, while enumeration (`query`, `create`, `windows.*`, window/active semantics) cannot. This matches S1 C4b (count 1, `sender.tab.url` still present).

Consequences for the design: any tab that Noche shows must be a tab of a `Browser` for `chrome.tabs.query` to equal Noche's tab count. This is why the recommendation below moves every tab into the Chrome-style Browser instead of patching enumeration to include Alloy tabs.

Side effect to plan for: the views-hosted Browser reports window type `popup` (`browser_extension_window_controller.cc:86-87`), so `tabs.query({windowType: "normal"})` returns nothing for Noche tabs, and `chrome.action.openPopup` is refused for it (see Q4). Small patch, listed below.

## Q4. Extension toolbar actions in Chrome's views code, and the smallest CEF API

Where they live:

- Model, per Profile: `ToolbarActionsModel` (`chrome/browser/ui/toolbar/toolbar_actions_model.h:78-117`: `Get(Profile*)` at :110, `Observer` with `OnToolbarActionAdded/Removed/Updated/PinnedActionsChanged`, `action_ids()`, `IsActionPinned`, `pinned_action_ids()`). It is toolkit-neutral and is kept current from `ExtensionRegistryObserver` and `ExtensionActionDispatcher::Observer` (`toolbar_actions_model.cc:107` `OnExtensionActionUpdated`).
- View model, per Browser and per action: `ExtensionActionViewModel` (`chrome/browser/ui/extensions/extension_action_view_model.h`, `Create` at `.cc:216`). It already exposes everything Noche needs: `GetIcon(web_contents, size)` (`.cc:284`, the badge text, text color and background color are baked into the icon by `GetIconImageSource`, `.cc:783-830`, from `ExtensionAction::GetDisplayBadgeText/GetBadgeTextColor/GetBadgeBackgroundColor`, `extensions/browser/extension_action.h:134,144,165`), `GetActionTitle` (`.cc:303`), `GetActionName`, `IsEnabled`, `ExecuteUserAction` (`.cc:468`) and `TriggerPopup` (`.cc:751`). Popup creation is `ExtensionViewHostFactory::CreatePopupHost(*extension_, popup_url, browser_)` (`.cc:769`), then handed to the delegate.
- Platform seam: `ExtensionActionDelegate` (`chrome/browser/ui/extensions/extension_action_delegate.h`, 10 pure virtuals plus the non-pure `GetActiveWebContents`: `AttachToModel`, `DetachFromModel`, `RegisterCommand`, `UnregisterCommand`, `IsShowingPopup`, `HidePopup`, `GetPopupNativeView`, `TriggerPopup`, `ShowContextMenuAsFallback`, `CloseExtensionsMenuIfOpen`) and `ExtensionsContainer` (`chrome/browser/ui/extensions/extensions_container.h`, found per Browser via `ExtensionsContainer::From`, `extensions_container.cc:12`). `GetActiveWebContents()` is the hook that fixes S1's "popup resolves current tab from its own window": `ExtensionActionViewModel::GetCurrentWebContents` (`.cc:618-628`) prefers the delegate's value over the Browser's active tab.
- Views implementation: `ExtensionActionDelegateDesktop::DoTriggerPopup/ShowPopup` (`chrome/browser/ui/views/extensions/extension_action_delegate_desktop.cc:44-98`) calls `ExtensionPopup::ShowPopup(browser, host, BubbleAnchor, arrow, show_action, callback)` (`chrome/browser/ui/views/extensions/extension_popup.h:63`, `.cc:59`). `BubbleAnchor` holds a `View*`, a `TrackedElement*` or nothing (`ui/views/bubble/bubble_anchor.h:43-80`), and the bubble base class supports a plain screen rect plus a parent window (`ui/views/bubble/bubble_dialog_delegate_view.h:305` `SetAnchorRect`, `:487` `set_parent_window`).
- Precedents that prove the seam is not views-bound: Android implements `ExtensionsContainer` with the same model in 457 lines (`chrome/browser/ui/android/extensions/extensions_toolbar_android.cc`, `ExtensionActionViewModel::Create` at :105), and WebUI in 784 lines (`chrome/browser/ui/webui/webui_toolbar/webui_toolbar_extensions_container.cc`).
- Why nothing exists in CEF: CEF patches the toolbar to be optional (`patch:chrome_runtime_views.patch`, hunks `toolbar_view.cc`, `BrowserView`), and `GetChromeToolbarType() = NONE` removes `ExtensionsToolbarDesktop`, so `ExtensionsContainer::From` is null for CEF Browsers. `chrome.action.openPopup` additionally requires `kFeatureToolbar` and a visible toolbar (`chrome/browser/extensions/api/extension_action/extension_action_api.cc:149-154`), which a `TYPE_POPUP` Browser never reports.

Smallest CEF API (new `cef/include/cef_extension_action.h`, per CefBrowserView so the right `Browser` is used):

```cpp
/*--cef(source=library)--*/
class CefExtensionAction : public virtual CefBaseRefCounted {
 public:
  /*--cef()--*/ virtual CefString GetId() = 0;                       // extension id
  /*--cef()--*/ virtual CefString GetName() = 0;
  /*--cef()--*/ virtual CefString GetTitle(CefRefPtr<CefBrowser> tab) = 0;
  /*--cef()--*/ virtual CefRefPtr<CefImage> GetIcon(CefRefPtr<CefBrowser> tab, int size_dip, float scale) = 0;  // badge baked in
  /*--cef()--*/ virtual bool GetBadge(CefRefPtr<CefBrowser> tab, CefString& text, cef_color_t& text_color, cef_color_t& background_color) = 0;
  /*--cef()--*/ virtual bool IsEnabled(CefRefPtr<CefBrowser> tab) = 0;
  /*--cef()--*/ virtual bool IsPinned() = 0;
  /*--cef()--*/ virtual bool Execute(CefRefPtr<CefBrowser> tab, const CefRect& anchor_screen_rect) = 0;     // runs action, opens popup if it has one
  /*--cef()--*/ virtual bool IsShowingPopup() = 0;
  /*--cef()--*/ virtual void HidePopup() = 0;
};

/*--cef(source=client)--*/
class CefExtensionActionObserver : public virtual CefBaseRefCounted {
 public:
  /*--cef()--*/ virtual void OnActionAdded(CefRefPtr<CefExtensionAction> action) {}
  /*--cef()--*/ virtual void OnActionRemoved(const CefString& extension_id) {}
  /*--cef()--*/ virtual void OnActionUpdated(CefRefPtr<CefExtensionAction> action) {}   // icon, title, badge
  /*--cef()--*/ virtual void OnPinnedActionsChanged() {}
};

// cef_browser_view.h additions
/*--cef()--*/ virtual void GetExtensionActions(std::vector<CefRefPtr<CefExtensionAction>>& actions) = 0;
/*--cef()--*/ virtual void AddExtensionActionObserver(CefRefPtr<CefExtensionActionObserver> observer) = 0;
```

The icon is returned as a `CefImage` of the already-composited icon and badge, so Noche needs no badge drawing. Popup anchoring takes a screen-space rect, which Swift computes from its `NSView` (`convertRect:toView:nil` then `convertRectToScreen:`). Implementation: a `CefExtensionActionDelegate : ExtensionActionDelegate` plus `CefExtensionsContainer : ExtensionsContainer` modelled on the Android one; `TriggerPopup` calls a new `ExtensionPopup::ShowPopup` overload that takes `(parent NativeView, gfx::Rect screen_anchor)` and uses a null `BubbleAnchor` followed by `SetAnchorRect`. The popup closes when the tab strip changes (`extension_popup.cc:299`, observer on `browser_->GetTabStripModel()`), which gives the right behaviour when Noche switches tabs.

Unverified: whether a bubble with a null anchor view, `SetAnchorWidget`, `set_parent_window` and an anchor rect in screen coordinates, parented to a CefWindow's NSWindow, positions and activates correctly on macOS (S1's NSPopover re-parenting rendered blank, which is a different mechanism). The bubble must also get `SetAnchorWidget`, otherwise the `CHECK(anchor_widget())` at `extension_popup.cc:301` fires. Experiment U5.

## Q5. Web Store "switch to Chrome" banner, the UA brand override, and the extra window on install

Banner and brand override:
- The store page and its decision logic are closed source and not in the tree, so the exact trigger cannot be read. What the source does establish: with a non-Google-branded build the UA brand list is `{GREASE brand, "Chromium"}` and the product brand entry is skipped (`components/embedder_support/user_agent_utils.cc:164-168` `#if !BUILDFLAG(CHROMIUM_BRANDING) brand = version_info::GetProductName()`, list built at :506-520). The open checkout has no `chrome/app/theme/google_chrome/BRANDING`, so no "Google Chrome" brand can be produced from this tree. The UA string product token is separately overridable through CEF's `user-agent-product` switch (`patch:embedder_product_override.patch`, `GetProductAndVersion` at `user_agent_utils.cc:461`).
- `chrome.webstorePrivate` itself is exposed by origin (`extensions/common/api/_api_features.json:967-970`, `https://chromewebstore.google.com/*`), independent of brand, so the install API is available in a Chromium-branded build.
- Best-supported answer (unverified): the page keys on Client Hints (`Sec-CH-UA` brand list and `navigator.userAgentData.brands`) and the banner is decided on the first document response. S1 applied its CDP brand override "before the click" on an already-loaded page, which would not change a banner chosen from the first request headers, and that fits the observation that `c2-store2.png` is pixel-identical to `c2-store.png`. Experiments U3 and U4 settle it before any patch is written.
- Fix if confirmed: a CEF patch to `GetUserAgentBrandList` to add a configurable brand entry so the header is correct from the first request (about 15 lines, one component file).

The extra Chrome window during install:
- Cause: `ExtensionInstallUIDesktop::OnInstallSuccess` (`chrome/browser/ui/extensions/extension_install_ui_desktop.cc:119-150`) calls `FindOrCreateVisibleBrowser` (:72-79), which builds a `chrome::ScopedTabbedBrowserDisplayer` (`chrome/browser/ui/scoped_tabbed_browser_displayer.cc:14-36`). That uses `FindTabbedBrowser` (`TYPE_NORMAL` only, `profile_browser_collection.cc:27-50`), creates a default normal Browser when none exists (:17-21), adds an empty New Tab page when the strip is empty (`extension_install_ui_desktop.cc:75-77`), and calls `GetWindow()->Show()` in the destructor (`scoped_tabbed_browser_displayer.cc:35`). The post-install dialog then anchors to that Browser's active tab (:136-150, `TriggerPostInstallDialog` at `chrome/browser/ui/extensions/extension_post_install_dialog.cc:193`). The failure path uses `GetLastActiveBrowser` instead (`extension_install_ui_desktop.cc:185-199`) and does not create a window.
- This is not patched by CEF (no patch touches `extension_install_ui_desktop.cc` or `scoped_tabbed_browser_displayer.cc`).
- Fix: in `OnInstallSuccess`, prefer the Browser that owns the web contents the install came from (the Web Store tab) or any views-hosted Browser of the profile, before falling back. Webstore installs can already opt out of the post-install UI per install via `InstallApproval::skip_post_install_ui` (`chrome/browser/extensions/webstore_standalone_installer.cc:179`, `extensions/browser/install_approval.cc:35`), a second, even smaller option (no dialog). `OnInstallSuccess` also runs for Web Store initiated installs (through `WebstoreInstaller`). The install confirmation prompt is already parented to the store tab (`ExtensionInstallPrompt(GetWebContents(), ...)`, `webstore_standalone_installer.cc:170-171`), so it should need no change; the P3 test checks that. Also related: any other `GetOrCreateBrowser` caller (extension options pages, welcome pages opened with `chrome.tabs.create` from a service worker) is fixed by the navigator patch P1.

## Recommended tab architecture

**One Chrome-style Browser per Noche window holding all tabs in its `TabStripModel`; the app activates the visible tab. No Alloy tabs.**

Why this one:
- It is the only layout where `chrome.tabs.query` count equals Noche's tab count with no enumeration hacks (Q3), where `activeTab` and action popups resolve the current tab through Chrome's own machinery (Q4), and where install, options and welcome pages land in the right Browser (Q5).
- Tab switch is Chrome's `TabStripModel::ActivateTabAt` -> `BrowserView::OnActiveTabChanged` swap inside one view, with no window or compositor reparenting, so latency should be at or near the hybrid's 9.7 ms median and well under window-per-tab's 25.8 ms (S1 C4). Unverified, experiment U2.
- Memory: one Browser, N WebContents, no extra windows; the 20-tab hybrid figure (2.6 GB, 25 processes) is the comparison point.
- Rounded card, sidebar as sibling view, frameless: all S1 C1, C3, C6 results are about the single Chrome-style window and carry over unchanged.

Main risk: **CEF's one-CefBrowser-per-CefBrowserView invariant** (blocker 2 in Q2). `GetBrowser()`, `OnBrowserCreated/Destroyed`, `BrowserDestroyed`'s `DCHECK`, and close semantics (closing the last tab closes the Browser and the window, `chrome_browser_host_impl.cc:589-600`) all assume one tab. Getting this wrong shows up as use-after-free or a window that closes with its last tab, so it is the first patch and carries the most tests. Secondary risks: Chrome's tab lifecycle (discard and freeze of background tabs under memory pressure) acting on Noche tabs, and the `popup` window type visible to extensions.

Rejected alternatives (kept for the record, not options): window-per-tab works today but costs 25.8 ms median switch and 3.4 GB at 20 tabs and still exposes N one-tab windows to `chrome.windows`; the M0 hybrid keeps `chrome.tabs.query` blind to Alloy tabs (Q3) and lacks `activeTab` coverage.

## Ranked patch list

Rebuild scope key: few files = under 10 translation units plus link; component = one Chromium component plus link; most of chrome = a header change that fans out. All sizes are rough lines changed. Order is dependency order, which is also priority order.

### P1. Tabs inside a Views-hosted Chrome Browser (blocks everything)
- Touches: `chrome/browser/ui/navigator/browser_navigator.cc` (`WindowCanOpenTabs`, :121-137, return true when `params.browser->cef_delegate()` and `IsViewsHosted()`); `cef/libcef/browser/chrome/chrome_browser_delegate.cc` (`SetAsDelegate` :234-275: second and later tabs use a tab delegate that does not rebind the view); `cef/libcef/browser/views/browser_view_impl.cc/.h` (`browser_` becomes the active tab, track the set); `cef/libcef/browser/chrome/chrome_browser_host_impl.cc` (`DoCloseBrowser` :589, `OnSetFocus` :152, `AddNewContents` :114, relax `DCHECK(!browser_)` for the tab case); `cef/libcef/browser/browser_info_manager.cc` (`CanCreateWindow` :112-239, `ShouldCreateViewsHostedPopup` :549-563: popup-to-tab redirect, below); a `TabStripModelObserver` added to `cef/libcef/browser/chrome/views/chrome_browser_view.cc`; `cef/libcef/browser/chrome/views/browser_platform_delegate_chrome_views.cc`; `cef/include/views/cef_browser_view.h`, `cef_browser_view_delegate.h`.
- New API:
  ```cpp
  // CefBrowserView
  /*--cef()--*/ virtual CefRefPtr<CefBrowser> AddTab(const CefString& url, CefRefPtr<CefClient> client, const CefBrowserSettings& settings, CefRefPtr<CefDictionaryValue> extra_info, bool activate) = 0;
  /*--cef()--*/ virtual void SetActiveTab(CefRefPtr<CefBrowser> tab) = 0;
  /*--cef()--*/ virtual CefRefPtr<CefBrowser> GetActiveTab() = 0;
  /*--cef()--*/ virtual void GetTabs(std::vector<CefRefPtr<CefBrowser>>& tabs) = 0;
  // CefBrowserViewDelegate
  /*--cef()--*/ virtual void OnTabAdded(CefRefPtr<CefBrowserView> view, CefRefPtr<CefBrowser> tab, bool active) {}
  /*--cef()--*/ virtual void OnActiveTabChanged(CefRefPtr<CefBrowserView> view, CefRefPtr<CefBrowser> previous, CefRefPtr<CefBrowser> active) {}
  /*--cef()--*/ virtual void OnTabClosed(CefRefPtr<CefBrowserView> view, CefRefPtr<CefBrowser> tab) {}
  ```
  `GetBrowser()` is redefined as the active tab.
  Three mechanisms P1 must specify:
  - Popup to tab. Handled `OnBeforePopup` popups go through `CanCreateWindow` -> `AddNewContents` and always make a new Browser and window (`browser_info_manager.cc:225,549-563`; `AddNewContents` has `DCHECK(!browser_)`), so the relaxed navigator check only covers the unhandled-popup, `chrome.tabs.create` and `IDC_NEW_TAB` paths. Add a rule: when the opener is a Views-hosted Chrome-style Browser and the disposition is a tab disposition (`NEW_FOREGROUND_TAB`, `NEW_BACKGROUND_TAB`) and the client does not claim the popup, set `use_default_browser_creation` so the contents go to the opener's Browser through the navigator, and fire `OnTabAdded`. Window dispositions keep the new-window path.
  - Per-tab client, settings, extra_info. `SetAsDelegate` builds each host from the Browser delegate's single `create_params_` (`chrome_browser_delegate.cc:256-274`) and is the only path for tabs created through `OnWebContentsCreated`. Hand-off: `AddTab` pushes a pending-tab-params entry (client, settings, extra_info, url) onto a queue owned by the `ChromeBrowserDelegate`; `SetAsDelegate` pops it for the next created WebContents and falls back to `create_params_` (the first tab's client) for tabs Chrome creates itself (extensions, Cmd+T). Unproven, U9.
  - Active-tab tracking. `CefBrowserViewImpl::browser_` (`browser_view_impl.cc:185-190`) must follow every active-tab change, including changes made outside CEF such as `chrome.tabs.update({active:true})`. Hook: a `TabStripModelObserver` on the Browser's `TabStripModel` (the notification `BrowserView::OnActiveTabChanged` uses) sets `browser_` and fires `OnActiveTabChanged`; `SetActiveTab` is then just `ActivateTabAt`. `OnSetFocus` (`chrome_browser_host_impl.cc:152-171`, `SelectNumberedTab`) is a usable stop-gap. `AddTab` calls `chrome::AddAndReturnTabAt` (`browser_tabstrip.cc:44`), `SetActiveTab` calls `TabStripModel::ActivateTabAt`.
- Size: about 400 to 600 lines in CEF plus 5 lines in Chromium. Rebuild: Chromium side one file in `chrome/browser/ui`; most of the work is `libcef` and relink.
- Test (S1 style): Noche spike opens 20 tabs in one Chrome-style view; extension service worker `chrome.tabs.query({})` returns 20 with `sender.tab` matching; `SetActiveTab` 10 times, record click-to-`requestAnimationFrame` latency (compare 9.7 ms and 25.8 ms); closing a non-last tab keeps the window; `target=_blank` (with `OnBeforePopup` both claimed-as-tab and unhandled) and `chrome.tabs.create` land in the same view and fire `OnTabAdded`; a per-tab client passed to `AddTab` gets that tab's `OnAfterCreated`; `chrome.tabs.update({active:true})` from an extension updates `GetActiveTab()`; no second window exists (`CGWindowListCopyWindowInfo` count).

### P2. Extension actions API and popup in a Noche-anchored bubble
- Touches: new `cef/libcef/browser/chrome/extensions/extension_action_*.cc/.h` (delegate, container, observer bridge, modelled on `chrome/browser/ui/android/extensions/extensions_toolbar_android.cc`); `chrome/browser/ui/views/extensions/extension_popup.cc/.h` (overload taking the CEF `Widget*` and a screen anchor rect: null `BubbleAnchor`, then `SetAnchorWidget(cef_widget)`, `set_parent_window`, `SetAnchorRect`. `SetAnchorWidget` is required because the popup does `CHECK(anchor_widget())` and `anchor_widget()->GetPrimaryWindowWidget()` at `extension_popup.cc:301-302`, and `anchor_widget_` is only set by `SetAnchorWidget` or implied by an anchor view, `ui/views/bubble/bubble_dialog_delegate_view.h:341-343`); `chrome/browser/extensions/api/extension_action/extension_action_api.cc` (:149-154: the toolbar check uses `SupportsWindowFeature(kFeatureToolbar)` and `BrowserWindow::IsToolbarVisible()`. A smaller option than editing this file is to have the existing CEF `cef_delegate()->SupportsWindowFeature` hook return true for `kFeatureToolbar` on Views-hosted Browsers, plus `IsToolbarVisible()` (`browser_view.cc:3126`) returning true. Unverified whether that has layout side effects since `BrowserView` also reads the feature; choose after U5); `cef/include/cef_extension_action.h`; `cef/include/views/cef_browser_view.h`.
- New API: the `CefExtensionAction`, `CefExtensionActionObserver` and `CefBrowserView` additions in Q4.
- Size: about 600 to 900 lines in CEF, about 40 in Chromium. Rebuild: `extension_popup.cc` and `extension_action_api.cc` (component `chrome/browser/ui` and `chrome/browser/extensions`), libcef, relink.
- Test: install a test MV3 extension with `default_popup`, `chrome.action.setBadgeText`, and `setBadgeBackgroundColor`; Swift lists actions through the API and the observer fires on badge change; icon `CefImage` has non-transparent pixels and badge text; `Execute` with the rect of a Noche `NSButton` shows the popup anchored below that rect; popup content reports the `tabId` of the Noche active tab (fixes S1 C5 "not a website"); switching tab closes the popup.

### P3. Install flow lands in the originating Browser, no extra window
- Touches: `chrome/browser/ui/extensions/extension_install_ui_desktop.cc` (:72-79 `FindOrCreateVisibleBrowser`, :136-150); `chrome/browser/ui/scoped_tabbed_browser_displayer.cc` only if a global rule is preferred (`FindTabbedBrowser` accepting a CEF views-hosted Browser when no normal one exists, `profile_browser_collection.cc:27-50`).
- New API: none required. Optional `CefBrowserViewDelegate::ShouldShowExtensionPostInstallUI(view)` returning false to map to `skip_post_install_ui`.
- Size: about 20 to 40 lines. Rebuild: few files (one `.cc` in `chrome/browser/ui`), relink.
- Test: Web Store install of the S1 extension; `CGWindowListCopyWindowInfo` shows exactly the Noche windows before and after install; no New Tab page is created; the install confirmation sheet still appears and the extension shows up in P2's `GetExtensionActions`.

### P4. Client Hints brand from the first request
- Touches: `components/embedder_support/user_agent_utils.cc` (`GetUserAgentBrandList`, :157-177; add an optional brand read from a CEF switch alongside `user-agent-product` from `patch:embedder_product_override.patch`); `cef/libcef/common/main_delegate` switch wiring and a `CefSettings` field.
- New API: `CefSettings::user_agent_brand` (string) or `--user-agent-brand`.
- Size: about 20 lines. Rebuild: component (`components/embedder_support`), plus relink; every `chrome` user of the component recompiles only if the header changes (it does not).
- Test: stock UA (no CDP override) opens the Web Store; banner absent or present as recorded; `Network.requestWillBeSent` for the store document shows the intended `Sec-CH-UA`; install completes. If U3 shows the brand is NOT the trigger, drop this patch.

### P5. Extension window identity (small, optional until an extension needs it)
- Touches: `chrome/browser/extensions/browser_extension_window_controller.cc` (:86-87, report `normal` for CEF views-hosted Browsers) and `chrome/browser/extensions/api/tabs/tabs_api.cc` (:1942 `MatchesWindow`).
- Size: about 15 lines. Rebuild: few files in `chrome/browser/extensions`.
- Test: `chrome.windows.getAll({windowTypes:["normal"]})` and `tabs.query({windowType:"normal"})` return the Noche window and tabs.

Total new surface is dominated by P1 and P2. P1 and P3 are the cheapest to prove first.

## Unverified items and the experiment that settles each

- U1. A second `ChromeBrowserHostImpl` bound to an existing `CefBrowserViewImpl` works once `WindowCanOpenTabs` is relaxed (blocker 2, Q2). Experiment: apply only the 5-line navigator patch, run the S1 spike, call `ExecuteChromeCommand(IDC_NEW_TAB)` and a `target=_blank` link, and read the DCHECK or crash output from a debug-asserts build, plus whether `OnAfterCreated` fires for the new tab. Sizes P1.
- U2. Tab-switch latency of `ActivateTabAt` inside one Browser. Experiment: S1 C4 method (10 sidebar clicks, click log time to next `requestAnimationFrame` via CDP, screen unlocked) on the P1 build, compared with 9.7 ms and 25.8 ms.
- U3. What makes the store show the banner (UA string, `Sec-CH-UA`, `navigator.userAgentData`, or something else). Experiment: in the S1 harness set the CDP `Emulation.setUserAgentOverride` with brand metadata on a blank page BEFORE the first navigation to the store, capture the store document request headers, and compare banner and button state across four cases: stock, UA only, brand only, UA plus brand.
- U4. Whether install works without any override. Experiment: stock UA, click the store button (or call `chrome.webstorePrivate.beginInstallWithManifest3` flow through the store UI) and record whether the prompt appears and the install completes.
- U5. A null-anchor `ExtensionPopup` with `SetAnchorWidget`, parent window and screen rect (and, as the alternative to editing `extension_action_api.cc`, a `SupportsWindowFeature(kFeatureToolbar)` hook) positions and takes focus correctly on macOS from an AppKit button. Experiment: the P2 overload driven from the S1 spike's sidebar button, screenshot and click inside the popup.
- U6. Background tabs in the single Browser are not discarded or frozen under pressure in a way that breaks Noche expectations, and RSS at 20 tabs. Experiment: P1 build with 20 loaded tabs, sample RSS twice a minute apart (S1 method), run with a memory-pressure simulation (`chrome://discards` state via CDP-visible `WasDiscarded`).
- U7. Behaviour when the last tab closes (window closes with the Browser, `chrome_browser_host_impl.cc:589-600`) and whether Noche can keep an empty window. Experiment: close tab 20 of 20 and observe `OnBrowserDestroyed` and window lifetime; decide between a placeholder tab and a patch.
- U9. Per-tab client, settings and extra_info reach the right host through a pending-tab-params queue in `SetAsDelegate`, including when Chrome creates a tab itself. Experiment: P1 build, `AddTab` with two distinct clients, assert each client's `OnAfterCreated` fires once for its own tab; then press Cmd+T and check the fallback client gets that tab.
- U8. `chrome.tabs.sendMessage` and `activeTab` against an Alloy tab (S1 left it untested). Moot under the recommendation, listed only to close the M0 question: a 10-line addition to the S1 test extension.

## Files I could not find

- None needed: `chromium/src/cef` appeared after I started, and I read CEF from `chromium_git/cef` (identical). All cited Chromium directories (chrome/browser, extensions, components, ui/views) were present.
- `chrome/app/theme/google_chrome/BRANDING` and any Google-branded resources are absent (closed source).
- The Web Store page source and server logic (banner trigger) are not in any tree.
