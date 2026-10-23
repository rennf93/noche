// Helper subprocess main for the Noche shell. CEF on macOS launches all
// subprocesses (renderer, gpu, utility, plugin) from a single helper app
// bundle, "Noche Helper.app" in the outer app's Contents/Frameworks; the
// process type arrives on the command line as --type=<type>. Every CEF
// process other than the browser process ends up here.
//
// The helper loads the outer app's CEF framework at runtime via
// CefScopedLibraryLoader::LoadInHelper (which resolves ../../.. from this
// executable up to Contents/Frameworks) and then hands control to
// CefExecuteProcess, which never returns.

#import <Foundation/Foundation.h>

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

class HelperApp : public CefApp {
 public:
  HelperApp() = default;

 private:
  IMPLEMENT_REFCOUNTING(HelperApp);
  DISALLOW_COPY_AND_ASSIGN(HelperApp);
};

}  // namespace

int main(int argc, char* argv[]) {
  // Initialize the sandbox for this subprocess before anything else. With the
  // browser process built for sandboxing (default no_sandbox=0), every child
  // is expected to apply its seatbelt profile here.
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    fprintf(stderr, "[noche helper] sandbox initialization failed\n");
    return 1;
  }

  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    fprintf(stderr, "[noche helper] failed to load the CEF framework\n");
    return 1;
  }

  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, new HelperApp(), nullptr);
}
