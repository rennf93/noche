#import <AppKit/AppKit.h>

#ifndef NC_EXPORT
#define NC_EXPORT __attribute__((visibility("default")))
#endif

NS_ASSUME_NONNULL_BEGIN

@class NCDownloads;

typedef NS_ENUM(NSInteger, NCDownloadState) { NCDownloadStateInProgress, NCDownloadStatePaused, NCDownloadStateComplete, NCDownloadStateCanceled, NCDownloadStateInterrupted };

/// One download as the engine last reported it: an immutable copy, a later update is a new object with the same |identifier|.
NC_EXPORT
@interface NCDownloadItem : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) uint32_t identifier;                 // the engine's id, stable for the profile
@property(nonatomic, readonly, copy) NSString *url, *suggestedName;
@property(nonatomic, readonly, copy) NSString *fullPath;            // empty until the engine chose the target
@property(nonatomic, readonly) int64_t receivedBytes;
@property(nonatomic, readonly) int64_t totalBytes;                  // -1 when the server sent no length
@property(nonatomic, readonly) NSInteger percent;                   // 0 to 100, -1 when unknown
@property(nonatomic, readonly) int64_t speed;                       // bytes per second
@property(nonatomic, readonly) NCDownloadState state;
@end

/// Every callback arrives on the main thread, from a task posted after the CEF callback that caused it.
NS_SWIFT_UI_ACTOR
@protocol NCDownloadsObserver <NSObject>
/// Every update of every download of the profile, whether its tab is open, closed, or the item was restored from history at startup.
- (void)downloads:(NCDownloads *)downloads didUpdate:(NCDownloadItem *)item;
@end

/// The profile's downloads (one per process: the global request context). Downloads from a live tab and downloads with no tab (the tab
/// closed, restored from history) reach the same observer. Noche never asks for a path: Chromium's target determiner picks it from the
/// profile's download directory (setDownloadDirectory:), keeps the " (1)" suffix rule and shows no save dialog.
NC_EXPORT NS_SWIFT_UI_ACTOR
@interface NCDownloads : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property(class, nonatomic, readonly) NCDownloads *shared;
/// Installs the profile level handler (items that already exist are announced at once) and delivers every update to |observer| (weak).
- (void)startWithObserver:(id<NCDownloadsObserver>)observer NS_SWIFT_NAME(start(observer:));
/// The latest copy of every download seen since start, in the order first seen.
@property(nonatomic, readonly) NSArray<NCDownloadItem *> *items;
- (void)pause:(uint32_t)identifier;
- (void)resume:(uint32_t)identifier;
- (void)cancel:(uint32_t)identifier;
/// Asks the engine to pause every download in progress, for the quit path: a paused download survives a clean quit (engine patch 0008) and
/// resumes at the next launch. Returns how many pauses were asked. The engine applies them asynchronously.
- (NSInteger)pauseAllForQuit;
@end

NS_ASSUME_NONNULL_END
