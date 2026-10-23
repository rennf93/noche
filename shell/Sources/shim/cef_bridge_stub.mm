// Stub implementation of the noche_* C API used when the CEF distribution is
// NOT vendored in shell/deps/. build.sh compiles this file instead of
// cef_bridge.mm in stub mode, so the Swift target and the cef_bridge.h
// interface stay identical in both modes.

#include <cstdio>

#include "cef_bridge.h"

int noche_cef_execute_process(void) {
  return -1;  // always the browser process
}

int noche_cef_initialize(const char* cacheRoot, const char* logFile) {
  std::fprintf(stderr,
               "[noche] stub mode: CEF not vendored (run "
               "shell/scripts/fetch-cef.sh); browser region stays a "
               "placeholder\n");
  return 0;
}

void noche_cef_set_on_browser_created(noche_cef_on_browser_created_t cb) {}

int noche_cef_create_browser(void* parent_view, const char* url) {
  return 0;
}

void noche_cef_set_load_hook(const char* path) {}

void noche_cef_shutdown(void) {}
