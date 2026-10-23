// CEF shim: implements the noche_* C API declared in cef_bridge.h on top of
// CEF (Chromium Embedded Framework). This file is compiled by build.sh only
// when the CEF binary distribution is vendored in shell/deps/.
//
// Key facts driving the design (both verified against the vendored headers):
// - CEF 156 on macOS requires the framework to be loaded at runtime, not
//   linked directly (include/wrapper/cef_library_loader.h). CefScopedLibraryLoader
//   resolves ../Frameworks relative to this executable, so the app must keep
//   the standard Contents/Frameworks layout.
// - The C API entry points (cef_execute_process and friends) are provided by
//   the libcef_dll wrapper static library via dlsym forwarders
//   (libcef_dll/wrapper/libcef_dll_dylib.cc); they only work after
//   cef_load_library(). The C++ classes here (CefApp, CefClient, ...) sit on
//   top of those forwarders, so all of it goes through the loaded framework.
//
// Process model: the helper binary (helper_main.mm) is a separate executable
// in "Noche Helper.app" that calls CefExecuteProcess and exits. The main
// binary also calls CefExecuteProcess first (it returns -1 in the browser
// process) so that a helper accidentally launched from the main executable
// still works.
//
// View model: windowed Alloy embedding via CefWindowInfo.SetAsChild(parent).
// CEF creates and parents its native browser view under |parent_view| itself;
// there is no GetNativeView accessor in the 156 headers. OnAfterCreated hands
// that CEF-added subview to the registered callback so the Swift side can
// mount it through BrowserViewStub.installBrowserView(_:) (the mount seam).

#import <AppKit/AppKit.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_command_line.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/wrapper/cef_library_loader.h"

#include "cef_bridge.h"

// ---------------------------------------------------------------------------
// Message pump integration. The shell runs NSApplication.run(); CEF must not
// own the main loop. With settings.external_message_pump = 1, CEF calls
// OnScheduleMessagePumpWork(delay_ms) from any thread whenever it has queued
// UI-thread work, and we service it with CefDoMessageLoopWork() on the main
// thread via a one-shot run-loop timer. Without this, browser-side UI-thread
// tasks never run while NSApp pumps: CefInitialize still returns and the GPU
// child still connects, but the utility subprocesses never get their mojo
// channel completed and starve to death at the 15 s watchdog
// (child_thread_impl.cc:931 "no connection") - reproduced 1:1 in
// shell/build/minhost3.mm, which differs from the working minhost2 only in
// owning the loop with NSApp vs CefRunMessageLoop.

@interface NochePumpScheduler : NSObject
// Main thread only. Ensures CefDoMessageLoopWork() is being serviced from the
// NSApp run loop. |delayMs| is honored lazily: the heartbeat interval is far
// below any delay CEF schedules with, so work always runs within its deadline.
- (void)schedulePumpWithDelayMs:(int64_t)delayMs;
@end

static NochePumpScheduler* g_pump_scheduler = nil;

@implementation NochePumpScheduler {
  NSTimer* _heartbeat;
}

- (void)schedulePumpWithDelayMs:(int64_t)delayMs {
  if (_heartbeat) {
    return;
  }
  // A repeating heartbeat is the pragmatic equivalent of letting
  // CefRunMessageLoop own the loop: one CefDoMessageLoopWork() call per
  // 2 ms run-loop pass. A schedule-only one-shot timer proved NOT sufficient
  // (utility children still starved at the 15 s watchdog in shell/build/
  // minhost3.mm with the scheduled-only variant), because channel-completion
  // tasks do not always arrive through OnScheduleMessagePumpWork before their
  // consumers need them drained.
  _heartbeat = [NSTimer timerWithTimeInterval:0.002
                                       target:self
                                     selector:@selector(pump:)
                                     userInfo:nil
                                      repeats:YES];
  [[NSRunLoop mainRunLoop] addTimer:_heartbeat forMode:NSRunLoopCommonModes];
}

- (void)pump:(NSTimer*)timer {
  CefDoMessageLoopWork();
}

@end

namespace {

// Globals used by the client handlers; declared before NocheClient so the
// class methods see them.
noche_cef_on_browser_created_t g_on_browser_created = nullptr;
std::string g_load_hook_path;
std::string g_last_title;
NSView* g_parent_view = nil;

// ---------------------------------------------------------------------------
// argv reconstruction. C API needs cef_main_args_t; build it from
// NSProcessInfo so the Swift side does not have to thread argc/argv through.
std::vector<char*> g_argv;
cef_main_args_t MainArgs() {
  if (g_argv.empty()) {
    NSArray<NSString*>* args = [[NSProcessInfo processInfo] arguments];
    for (NSString* arg in args) {
      g_argv.push_back(const_cast<char*>(arg.fileSystemRepresentation ?: ""));
    }
  }
  cef_main_args_t main_args;
  main_args.argc = static_cast<int>(g_argv.size());
  main_args.argv = g_argv.data();
  return main_args;
}

// ---------------------------------------------------------------------------
// App: CefApp. No customization needed yet; the object exists because
// CefExecuteProcess/CefInitialize require one.
class NocheApp : public CefApp,
                 public CefBrowserProcessHandler {
 public:
  NocheApp() = default;

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  // External message pump contract (see the pump-integration comment above):
  // CEF tells us when UI-thread work is waiting; service it from NSApp's run
  // loop. May be called from any thread, so always hop to main.
  void OnScheduleMessagePumpWork(int64_t delay_ms) override {
    if (!g_pump_scheduler) {
      g_pump_scheduler = [NochePumpScheduler new];
    }
    NochePumpScheduler* scheduler = g_pump_scheduler;
    if ([NSThread isMainThread]) {
      [scheduler schedulePumpWithDelayMs:delay_ms];
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        [scheduler schedulePumpWithDelayMs:delay_ms];
      });
    }
  }

  // Debug aid while the subprocess wiring is young: dump every child command
  // line, force child processes to log verbosely to stderr, and (when
  // NOCHE_CEF_IPC_TIMEOUT is set) extend the child connection watchdog so
  // stalled children stay alive for sampling instead of dying at 15 s.
  void OnBeforeChildProcessLaunch(
      CefRefPtr<CefCommandLine> command_line) override {
    std::vector<CefString> argv;
    command_line->GetArgv(argv);
    std::fprintf(stderr, "[noche cef] child command line:");
    for (const auto& arg : argv) {
      std::fprintf(stderr, " %s", arg.ToString().c_str());
    }
    std::fprintf(stderr, "\n");
    // NOCHE_NO_CHILD_FLAGS skips the debug flags below so children launch with
    // the exact command lines cefclient would use. Debug aid for isolating the
    // utility-process handshake stall.
    if (std::getenv("NOCHE_NO_CHILD_FLAGS")) {
      return;
    }
    command_line->AppendSwitchWithValue("enable-logging", "stderr");
    command_line->AppendSwitchWithValue("v", "1");
    const char* ipcTimeout = std::getenv("NOCHE_CEF_IPC_TIMEOUT");
    if (ipcTimeout && *ipcTimeout) {
      command_line->AppendSwitchWithValue("ipc-connection-timeout", ipcTimeout);
    }
  }

 private:
  IMPLEMENT_REFCOUNTING(NocheApp);
  DISALLOW_COPY_AND_ASSIGN(NocheApp);
};

CefRefPtr<NocheApp> g_app;
std::unique_ptr<CefScopedLibraryLoader> g_library_loader;
bool g_initialized = false;

// ---------------------------------------------------------------------------
// Client: the per-browser handler bundle. We implement life span, load and
// display handlers; everything else falls back to CEF defaults.
class NocheClient : public CefClient,
                    public CefLifeSpanHandler,
                    public CefLoadHandler,
                    public CefDisplayHandler {
 public:
  NocheClient() = default;

  // CefClient ---------------------------------------------------------------
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  // CefLifeSpanHandler ------------------------------------------------------
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    std::fprintf(stderr, "[noche cef] OnAfterCreated id=%d\n",
                 browser->GetIdentifier());
    if (g_on_browser_created) {
      // The browser was created with SetAsChild, so CEF's native view is now
      // a subview of the parent we handed in. Surface it to Swift.
      NSView* cefView = g_parent_view.subviews.lastObject;
      g_on_browser_created((__bridge void*)cefView);
    }
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    std::fprintf(stderr, "[noche cef] OnBeforeClose id=%d\n",
                 browser->GetIdentifier());
  }

  // CefLoadHandler ----------------------------------------------------------
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    std::fprintf(stderr,
                 "[noche cef] OnLoadingStateChange loading=%d canGoBack=%d "
                 "canGoForward=%d\n",
                 isLoading ? 1 : 0, canGoBack ? 1 : 0, canGoForward ? 1 : 0);
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    if (!frame->IsMain()) {
      return;
    }
    const std::string title = g_last_title;
    const std::string url = frame->GetURL().ToString();
    std::fprintf(stderr,
                 "[noche cef] OnLoadEnd status=%d title=\"%s\" url=\"%s\"\n",
                 httpStatusCode, title.c_str(), url.c_str());
    if (!g_load_hook_path.empty()) {
      std::ofstream hook(g_load_hook_path, std::ios::trunc);
      hook << title << "\t" << url << "\n";
      if (!hook) {
        std::fprintf(stderr, "[noche cef] failed writing hook file %s\n",
                     g_load_hook_path.c_str());
      }
    }
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override {
    if (frame->IsMain()) {
      std::fprintf(stderr, "[noche cef] OnLoadError code=%d text=\"%s\" url=\"%s\"\n",
                   errorCode, errorText.ToString().c_str(),
                   failedUrl.ToString().c_str());
    }
  }

  // CefDisplayHandler -------------------------------------------------------
  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override {
    g_last_title = title.ToString();
    std::fprintf(stderr, "[noche cef] OnTitleChange \"%s\"\n",
                 g_last_title.c_str());
  }

 private:
  IMPLEMENT_REFCOUNTING(NocheClient);
  DISALLOW_COPY_AND_ASSIGN(NocheClient);
};

CefRefPtr<NocheClient> g_client;

}  // namespace

// ---------------------------------------------------------------------------
// noche_* C API

int noche_cef_execute_process(void) {
  g_library_loader = std::make_unique<CefScopedLibraryLoader>();
  if (!g_library_loader->LoadInMain()) {
    std::fprintf(stderr, "[noche cef] failed to load the CEF framework\n");
    return 2;
  }
  if (!g_app) {
    g_app = new NocheApp();
  }
  const int exit_code = CefExecuteProcess(MainArgs(), g_app, nullptr);
  // -1 means "browser process, keep going"; anything else is a helper that
  // should terminate now.
  return exit_code;
}

int noche_cef_initialize(const char* cacheRoot, const char* logFile) {
  if (g_initialized) {
    return 1;
  }
  if (!g_app) {
    // Initialize was called without executeProcess (should not happen).
    return 0;
  }
  CefSettings settings;
  // Sandbox stays enabled (default): helper processes apply their own
  // seatbelt profile via CefScopedSandboxContext in helper_main.mm.
  // NSApplication.run() owns the main loop, so CEF must not: work is
  // delivered through OnScheduleMessagePumpWork -> CefDoMessageLoopWork.
  settings.external_message_pump = true;
  // NOCHE_CACHE_ROOT overrides the cache root; an empty value disables the
  // on-disk cache entirely (cefclient's default configuration). Debug aid for
  // isolating the utility-process handshake stall.
  const char* cacheOverride = std::getenv("NOCHE_CACHE_ROOT");
  if (cacheOverride) {
    cacheRoot = cacheOverride;
    std::fprintf(stderr, "[noche cef] NOCHE_CACHE_ROOT override: \"%s\"\n",
                 cacheRoot);
  }
  CefString(&settings.cache_path) = cacheRoot;
  CefString(&settings.log_file) = logFile;
  settings.log_severity = LOGSEVERITY_INFO;
  if (!std::getenv("NOCHE_NO_UA_OVERRIDE")) {
    CefString(&settings.user_agent_product) = "Noche/0.1.0";
  }
  settings.background_color = CefColorSetARGB(255, 26, 26, 28);

  if (!CefInitialize(MainArgs(), settings, g_app, nullptr)) {
    std::fprintf(stderr, "[noche cef] CefInitialize failed\n");
    return 0;
  }
  g_initialized = true;
  std::fprintf(stderr, "[noche cef] CefInitialize ok (cache=%s log=%s)\n",
               cacheRoot, logFile);
  return 1;
}

void noche_cef_set_on_browser_created(noche_cef_on_browser_created_t cb) {
  g_on_browser_created = cb;
}

int noche_cef_create_browser(void* parent_view, const char* url) {
  if (!g_initialized) {
    return 0;
  }
  if (!g_client) {
    g_client = new NocheClient();
  }
  NSView* parent = (__bridge NSView*)parent_view;
  g_parent_view = parent;

  CefWindowInfo window_info;
  // Mount seam: CEF parents its native browser view under the NSView the Swift
  // side hands in (BrowserViewStub); it autosizes with the parent.
  window_info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(parent),
                         CefRect(0, 0, 0, 0));
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  CefBrowserSettings browser_settings;
  browser_settings.background_color = CefColorSetARGB(255, 26, 26, 28);

  const bool ok = CefBrowserHost::CreateBrowser(window_info, g_client,
                                                CefString(url),
                                                browser_settings, nullptr,
                                                nullptr);
  if (!ok) {
    std::fprintf(stderr, "[noche cef] CreateBrowser failed\n");
    return 0;
  }
  return 1;
}

void noche_cef_set_load_hook(const char* path) {
  g_load_hook_path = path ? path : "";
}

void noche_cef_shutdown(void) {
  if (g_initialized) {
    CefShutdown();
    g_initialized = false;
    std::fprintf(stderr, "[noche cef] CefShutdown\n");
  }
  g_library_loader.reset();
}
