#pragma once
#include "include/cef_app.h"

// The CefApp handed to CefInitialize; its browser process handler drives the external message pump.
CefRefPtr<CefApp> NCCreateApp();
// Starts the fallback timer; call once after CefInitialize succeeds.
void NCPumpStart();
// Stops all pump timers; call before CefShutdown returns control to the app.
void NCPumpStop();
