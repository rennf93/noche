#import "CefBridge.h"
#include <crt_externs.h>
#include "NCInternal.h"
#include "include/wrapper/cef_library_loader.h"

static CefScopedLibraryLoader* g_loader = nullptr;

static BOOL Fail(NSError** error, NSString* step) {
  if (error) {
    *error = [NSError errorWithDomain:@"dev.noche.cef" code:1 userInfo:@{NSLocalizedDescriptionKey : step}];
  }
  return NO;
}

@implementation NCEngine

+ (BOOL)startWithCachePath:(NSString*)path error:(NSError**)error {
  if (g_loader) return Fail(error, @"already started");
  g_loader = new CefScopedLibraryLoader();
  if (!g_loader->LoadInMain()) {
    delete g_loader;
    g_loader = nullptr;
    return Fail(error, @"LoadInMain");
  }

  NSString* name = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
  NSString* helper = [NSString stringWithFormat:@"%@/%@ Helper.app/Contents/MacOS/%@ Helper",
                                                NSBundle.mainBundle.privateFrameworksPath, name, name];

  CefSettings settings;
  settings.no_sandbox = true;  // sandbox arrives with the signing task
  settings.external_message_pump = true;
  CefString(&settings.root_cache_path) = path.fileSystemRepresentation;
  CefString(&settings.cache_path) = path.fileSystemRepresentation;
  CefString(&settings.browser_subprocess_path) = helper.fileSystemRepresentation;

  int argc = *_NSGetArgc();
  CefMainArgs args(argc, *_NSGetArgv());
  if (!CefInitialize(args, settings, NCCreateApp(), nullptr)) {
    delete g_loader;
    g_loader = nullptr;
    return Fail(error, @"CefInitialize");
  }
  NCPumpStart();
  return YES;
}

+ (void)shutdown {
  if (!g_loader) return;
  NCPumpStop();
  CefShutdown();
  delete g_loader;
  g_loader = nullptr;
}

@end
