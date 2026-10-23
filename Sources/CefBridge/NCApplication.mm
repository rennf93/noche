#import "CefBridge.h"
#include "include/cef_application_mac.h"

@protocol NCTerminating <NSObject>
- (void)tryToTerminateApplication:(id)sender;
@end

@interface NCApplication () <CefAppProtocol>
@end

@implementation NCApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

// Route Cmd+Q to the delegate so browsers close before CefShutdown.
- (void)terminate:(id)sender {
  id<NCTerminating> delegate = (id<NCTerminating>)self.delegate;
  if ([delegate respondsToSelector:@selector(tryToTerminateApplication:)]) {
    [delegate tryToTerminateApplication:self];
  } else {
    [super terminate:sender];
  }
}

@end
