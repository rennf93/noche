#import <AppKit/AppKit.h>

// -fvisibility=hidden would otherwise make the classes local to the merged object.
#ifndef NC_EXPORT
#define NC_EXPORT __attribute__((visibility("default")))
#endif

#import "NCWindow.h"
#import "NCDownloads.h"

NS_ASSUME_NONNULL_BEGIN

/// NSApplication subclass implementing CEF's application protocol.
NC_EXPORT
@interface NCApplication : NSApplication
@end

NC_EXPORT
@interface NCEngine : NSObject
+ (BOOL)startWithCachePath:(NSString *)path error:(NSError *_Nullable *_Nullable)error;
+ (void)shutdown;
/// The numeric id of a Chrome command (IDC_...) in this engine build, -1 when the name is unknown. Valid once the engine started.
+ (NSInteger)chromeCommandIdNamed:(NSString *)name;
/// The CEF version string this app was compiled against (cef_version.h CEF_VERSION).
+ (NSString *)cefVersion;
/// Sets the profile preference `download.default_directory` (the folder Chromium puts new downloads in, with no save dialog). Call after the engine started.
/// Returns NO with |error| when the engine refused the value. Noche's default is ~/Downloads; Settings (M1.8) will store a user choice.
+ (BOOL)setDownloadDirectory:(NSString *)path error:(NSError *_Nullable *_Nullable)error;
@end

NC_EXPORT
@interface NCBrowserView : NSView
- (instancetype)initWithFrame:(NSRect)frame url:(NSString *)url NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
- (void)close;
/// YES once CEF has called DoClose for this browser (or when there is no browser): only then may the
/// host window close. Until then the window must ask the browser to close instead.
@property(nonatomic, readonly) BOOL mayClose;
@property(nonatomic, copy, nullable) void (^onLoadEnd)(NSInteger status);
@property(nonatomic, copy, nullable) void (^onLoadError)(NSInteger code);
@property(nonatomic, copy, nullable) void (^onTitleChange)(NSString *title);
@property(nonatomic, copy, nullable) void (^onClosed)(void);
@end

NS_ASSUME_NONNULL_END
