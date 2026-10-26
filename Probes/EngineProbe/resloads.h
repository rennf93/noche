// Records CefResourceRequestHandler::OnResourceLoadComplete (IO thread) for the 0008 kept-request checks, and answers HTTP Basic auth for the 0010
// ClearHttpAuthCredentials witness. Header-only, shared by surfaces.mm and profiles.mm.
#pragma once
#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <vector>
#include "include/cef_client.h"
#include "include/cef_load_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"

struct RlRec {
  std::string url;
  int browserId = -1;                // -1: the callback got a NULL browser
  int status = -1;                   // cef_urlrequest_status_t
  double ms = 0;                     // steady clock, same scale as RlNowMs()
  CefRefPtr<CefBrowser> browser;     // held so IsValid() can be read on the main thread afterwards
};
inline double RlNowMs() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

class RlRecorder : public CefRequestHandler, public CefResourceRequestHandler {
 public:
  std::atomic<bool> answerAuth{false};
  std::atomic<int> authAsked{0};
  std::string keepNeedle;  // set before use: only records whose URL holds it keep their CefBrowser (a browser still referenced at shutdown aborts the engine)
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest>, bool, bool, const CefString&, bool&) override { return this; }
  void OnResourceLoadComplete(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> req, CefRefPtr<CefResponse>, URLRequestStatus st, int64_t) override {
    RlRec r;
    r.url = req->GetURL().ToString(); r.browserId = b ? b->GetIdentifier() : -1; r.status = (int)st; r.ms = RlNowMs(); if (!keepNeedle.empty() && r.url.find(keepNeedle) != std::string::npos) r.browser = b;
    std::lock_guard<std::mutex> g(m_);
    recs_.push_back(r);
  }
  bool GetAuthCredentials(CefRefPtr<CefBrowser>, const CefString&, bool isProxy, const CefString&, int, const CefString&, const CefString&, CefRefPtr<CefAuthCallback> cb) override {
    if (isProxy || !answerAuth) return false;
    authAsked++;
    cb->Continue("noche", "probe");
    return true;
  }
  std::vector<RlRec> Recs(const std::string& needle) {
    std::lock_guard<std::mutex> g(m_);
    std::vector<RlRec> o;
    for (auto& r : recs_) if (r.url.find(needle) != std::string::npos) o.push_back(r);
    return o;
  }
  void Clear() { std::lock_guard<std::mutex> g(m_); recs_.clear(); }
 private:
  std::mutex m_;
  std::vector<RlRec> recs_;
  IMPLEMENT_REFCOUNTING(RlRecorder);
};

// A tab client that reports its requests to |rec| and its load ends to |loads|.
class RlClient : public CefClient, public CefLoadHandler {
 public:
  RlClient(CefRefPtr<RlRecorder> rec, CefRefPtr<CefDownloadHandler> dl) : rec_(rec), dl_(dl) {}
  std::atomic<int> loads{0};
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return rec_; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return dl_; }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> f, int) override { if (f->IsMain()) loads++; }
 private:
  CefRefPtr<RlRecorder> rec_;
  CefRefPtr<CefDownloadHandler> dl_;
  IMPLEMENT_REFCOUNTING(RlClient);
};
