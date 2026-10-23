#ifndef NOCHE_CEF_BRIDGE_H_
#define NOCHE_CEF_BRIDGE_H_

// C interface between the Swift app target and the CEF shim. One declaration
// point for both implementations: cef_bridge.mm (real, compiled when the CEF
// distribution is vendored in shell/deps/) and cef_bridge_stub.mm (no-op
// fallback so the app still builds without deps/).

#ifdef __cplusplus
extern "C" {
#endif

// Subprocess gate. Must be the first thing main.swift does. Returns -1 when
// this process should continue as the browser process; otherwise returns the
// exit code the caller must exit with (this process is a CEF helper).
int noche_cef_execute_process(void);

// CefInitialize on the main thread. |cacheRoot| receives CEF profile/cache
// data, |logFile| receives the CEF log. Returns 1 on success, 0 on failure.
int noche_cef_initialize(const char* cacheRoot, const char* logFile);

// Register the callback fired from CefLifeSpanHandler::OnAfterCreated with the
// browser's native NSView. |cb| may be null to clear. The callback runs on the
// main thread; Swift uses it to mount the view through BrowserViewStub.
typedef void (*noche_cef_on_browser_created_t)(void* native_view);
void noche_cef_set_on_browser_created(noche_cef_on_browser_created_t cb);

// Create a windowed browser parented to |parent_view| (an NSView*) loading
// |url|. Returns 1 if the create request was issued, 0 on failure.
int noche_cef_create_browser(void* parent_view, const char* url);

// Register the smoke-test hook path. On OnLoadEnd the shim writes one line
// "<page title>\t<url>" to this file. |path| may be null to disable.
void noche_cef_set_load_hook(const char* path);

// CefShutdown. Call on application termination.
void noche_cef_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif  // NOCHE_CEF_BRIDGE_H_
