#pragma once
#include "include/cef_app.h"
#include "include/cef_download_handler.h"

// The CefApp handed to CefInitialize; its browser process handler drives the external message pump.
CefRefPtr<CefApp> NCCreateApp();
// Starts the fallback timer; call once after CefInitialize succeeds.
void NCPumpStart();
// Stops all pump timers; call before CefShutdown returns control to the app.
void NCPumpStop();
// The download handler window clients return from GetDownloadHandler; it forwards every update to NCDownloads.
CefRefPtr<CefDownloadHandler> NCDownloadHandlerInstance();
