#include <unistd.h>

#include <cstdio>

#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
#ifdef NOCHE_SANDBOX
  // Must run before the framework is loaded (see cef_library_loader.h).
  CefScopedSandboxContext sandbox_context;
  bool ok = sandbox_context.Initialize(argc, argv);
  fprintf(stderr, "NOCHE-HELPER pid=%d sandbox-initialize=%d\n", getpid(), ok ? 1 : 0);
  if (!ok) return 1;
#endif
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  return CefExecuteProcess(CefMainArgs(argc, argv), nullptr, nullptr);
}
