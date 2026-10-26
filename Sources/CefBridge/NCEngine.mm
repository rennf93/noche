#include <vector>
#import "CefBridge.h"
#include <crt_externs.h>
#include "NCInternal.h"
#include "NCTabInternal.h"
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

// The engine content setting types a kind covers, each with the key Chromium's embargo record (PERMISSION_AUTOBLOCKER_DATA) files its counts under
// (PermissionUtil::GetPermissionString). The camera mask also covers pan-tilt-zoom (NCWindow.mm), so forgetting the camera clears both.
struct NCKindType { cef_content_setting_types_t type; const char* embargoKey; };
static std::vector<NCKindType> NCKindTypes(NSString* kind) {
  if ([kind isEqualToString:@"camera"]) {
    std::vector<NCKindType> t = {{CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA, "VideoCapture"}};
    if (!NC_TEST_FLAG("NOCHE_TEST_PERM_NOPTZ")) t.push_back({CEF_CONTENT_SETTING_TYPE_CAMERA_PAN_TILT_ZOOM, "CameraPanTiltZoom"});  // negative control
    return t;
  }
  if ([kind isEqualToString:@"camera-pan-tilt-zoom"]) return {{CEF_CONTENT_SETTING_TYPE_CAMERA_PAN_TILT_ZOOM, "CameraPanTiltZoom"}};
  if ([kind isEqualToString:@"microphone"]) return {{CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC, "AudioCapture"}};
  if ([kind isEqualToString:@"geolocation"]) return {{CEF_CONTENT_SETTING_TYPE_GEOLOCATION, "Geolocation"}};
  if ([kind isEqualToString:@"notifications"]) return {{CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS, "Notifications"}};
  return {};
}

// Mirrors PermissionDecisionAutoBlocker::RemoveEmbargoAndResetCounts: read the origin's record, drop only this kind's entry, write it back.
static void NCClearEmbargo(CefRefPtr<CefRequestContext> context, NSString* origin, const char* key) {
  if (NC_TEST_FLAG("NOCHE_TEST_PERM_KEEPEMBARGO")) return;  // negative control: dismissals stay counted
  CefRefPtr<CefValue> value = context->GetWebsiteSetting(origin.UTF8String, "", CEF_CONTENT_SETTING_TYPE_PERMISSION_AUTOBLOCKER_DATA);
  if (!value || value->GetType() != VTYPE_DICTIONARY) return;
  CefRefPtr<CefDictionaryValue> dict = value->GetDictionary()->Copy(false);
  if (!dict->Remove(key)) return;
  CefRefPtr<CefValue> updated = CefValue::Create();
  updated->SetDictionary(dict);
  context->SetWebsiteSetting(origin.UTF8String, "", CEF_CONTENT_SETTING_TYPE_PERMISSION_AUTOBLOCKER_DATA, updated);
}

static NSString* NCSettingName(cef_content_setting_values_t v) {
  switch (v) {
    case CEF_CONTENT_SETTING_VALUE_ALLOW: return @"allow";
    case CEF_CONTENT_SETTING_VALUE_BLOCK: return @"block";
    case CEF_CONTENT_SETTING_VALUE_ASK: return @"ask";
    case CEF_CONTENT_SETTING_VALUE_DEFAULT: return @"default";
    default: return @"other";
  }
}

+ (NSString*)contentSettingForOrigin:(NSString*)origin kind:(NSString*)kind { return [self contentSettingForOrigin:origin kind:kind topLevelOrigin:origin]; }

+ (NSString*)contentSettingForOrigin:(NSString*)origin kind:(NSString*)kind topLevelOrigin:(NSString*)top {
  CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
  auto types = NCKindTypes(kind);
  if (!context || types.empty()) return @"unknown kind";
  return NCSettingName(context->GetContentSetting(origin.UTF8String, top.UTF8String, types[0].type));
}

+ (void)resetContentSettingForOrigin:(NSString*)origin kind:(NSString*)kind {
  CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
  if (!context) return;
  for (const NCKindType& t : NCKindTypes(kind)) {
    context->SetContentSetting(origin.UTF8String, origin.UTF8String, t.type, CEF_CONTENT_SETTING_VALUE_DEFAULT);
    NCClearEmbargo(context, origin, t.embargoKey);
  }
}

#ifdef NOCHE_TESTHOOKS
+ (void)testBlockContentSettingForOrigin:(NSString*)origin kind:(NSString*)kind {
  CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
  if (!context) return;
  for (const NCKindType& t : NCKindTypes(kind)) context->SetContentSetting(origin.UTF8String, origin.UTF8String, t.type, CEF_CONTENT_SETTING_VALUE_BLOCK);
}
#endif

+ (void)shutdown {
  if (!g_loader) return;
  NCPumpStop();
  CefShutdown();
  delete g_loader;
  g_loader = nullptr;
}

@end
