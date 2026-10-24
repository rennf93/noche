#pragma once
#import "CefBridge.h"
#include "include/cef_browser.h"

// Bridge-private side of NCTab: NCWindow.mm mutates the state, the public header only reads it.
NS_ASSUME_NONNULL_BEGIN

@interface NCTab ()
@property(nonatomic, readwrite) NSInteger identifier;
@property(nonatomic, readwrite, copy) NSString* url;
@property(nonatomic, readwrite, copy) NSString* title;
@property(nonatomic, readwrite) BOOL isLoading, canGoBack, canGoForward;
@property(nonatomic, readwrite, nullable) NSImage* favicon;
/// Null once the browser is closed.
@property(nonatomic) CefRefPtr<CefBrowser> browser;
+ (instancetype)tabWithBrowser:(CefRefPtr<CefBrowser>)browser;
/// Drops the browser and the DevTools observer and fails every pending evaluation.
- (void)browserClosed;
/// Downloads the favicon at |url| (36 px) and calls |done| on the UI thread when it was set.
- (void)loadFaviconFromURL:(NSString*)url done:(void (^)(void))done;
@end

NS_ASSUME_NONNULL_END
