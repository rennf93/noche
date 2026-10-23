#import <AppKit/AppKit.h>

// -fvisibility=hidden would otherwise make the classes local to the merged object.
#define NC_EXPORT __attribute__((visibility("default")))

NS_ASSUME_NONNULL_BEGIN

/// NSApplication subclass implementing CEF's application protocol.
NC_EXPORT
@interface NCApplication : NSApplication
@end

NC_EXPORT
@interface NCEngine : NSObject
+ (BOOL)startWithCachePath:(NSString *)path error:(NSError *_Nullable *_Nullable)error;
+ (void)shutdown;
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
