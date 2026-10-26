#import "CefBridge.h"
#include <crt_externs.h>
#include "NCInternal.h"
#include "include/cef_id_mappers.h"
#include "include/cef_request_context.h"
#include "include/cef_values.h"
#include "include/cef_version.h"
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
#ifdef NOCHE_SANDBOX
  settings.no_sandbox = false;
#else
  settings.no_sandbox = true;
#endif
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

+ (NSInteger)chromeCommandIdNamed:(NSString*)name {
  return cef_id_for_command_id_name(name.UTF8String);
}

+ (NSString*)cefVersion {
  return @CEF_VERSION;
}

+ (BOOL)setDownloadDirectory:(NSString*)path error:(NSError**)error {
  CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
  CefRefPtr<CefValue> value = CefValue::Create();
  value->SetString(path.fileSystemRepresentation);
  CefString reason;
  if (!context || !context->SetPreference("download.default_directory", value, reason)) {
    return Fail(error, [NSString stringWithFormat:@"download.default_directory: %s", reason.ToString().c_str()]);
  }
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
