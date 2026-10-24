// Replays a recorded store run (docs/engine/evidence/b4-store-*.txt) through the install-no-window pass rule.
// usage: store_rule_test <evidence file> <expect: pass|fail>. The facts come from the PROBE lines of the run.
#include <fstream>
#include <iostream>
#include <string>
#include <vector>
#include "../EngineProbe/store_rule.h"

static int Count(const std::string& s, const std::string& needle) {
  int n = 0;
  for (size_t p = s.find(needle); p != std::string::npos; p = s.find(needle, p + 1)) n++;
  return n;
}

// One synthetic run per clause of the rule: a good run passes, and each single defect alone fails with its own reason.
static int ClauseCases() {
  auto good = [] { InstallFacts f; f.dialogSeen = true; return f; };
  struct Case { const char* name; InstallFacts f; const char* reason; };
  std::vector<Case> cases;
  { auto f = good(); f.browserWindowsAfter = 1; cases.push_back({"browser window after", f, "browser-window"}); }
  { auto f = good(); f.browserWindowOrders = 1; cases.push_back({"guard hit", f, "guard saw"}); }
  { auto f = good(); f.staleTabTargets = 1; cases.push_back({"stale new-tab target", f, "new-tab/apps targets=1"}); }
  { auto f = good(); f.staleTabTargets = -1; cases.push_back({"unanswered Target.getTargets", f, "unchecked"}); }
  { auto f = good(); f.dialogSeen = false; cases.push_back({"dialog not seen", f, "never appeared"}); }
  { auto f = good(); f.sameTabs = false; cases.push_back({"tabs changed", f, "tab count changed"}); }
  { auto f = good(); f.activateBlocked = 2; cases.push_back({"activate blocked", f, "activate the app 2 time"}); }
  std::string why;
  if (!InstallNoWindowOk(good(), &why)) { std::cout << "RULE BUG good synthetic run failed: " << why << "\n"; return 1; }
  for (auto& c : cases) {
    if (InstallNoWindowOk(c.f, &why)) { std::cout << "RULE BUG passed with " << c.name << "\n"; return 1; }
    if (why.find(c.reason) == std::string::npos) { std::cout << "RULE BUG " << c.name << " failed for another reason: " << why << "\n"; return 1; }
  }
  std::cout << "clauses ok: " << cases.size() << " single-defect runs each fail for their own reason\n";
  return 0;
}

int main(int argc, char** argv) {
  if (argc != 3) return 2;
  std::ifstream in(argv[1]);
  if (!in) { std::cerr << "cannot open evidence file " << argv[1] << "\n"; return 2; }  // a missing file must not read as the expected failure
  std::string line, before, after;
  if (int rc = ClauseCases()) return rc;
  InstallFacts f;
  f.staleTabTargets = 0;  // the recorded runs predate the target query; the replay checks the window rule
  f.activateBlocked = 0;  // the stock run's two blocked calls are the engine under test; the window clauses are what is replayed
  bool dialog = false;
  while (std::getline(in, line)) {
    if (line.find("info windows before:") != std::string::npos) before = line;
    if (line.find("info windows after:") != std::string::npos) after = line;
    // a guard line on the browser window class: order-in or makeKey
    if (line.find("info guard ") != std::string::npos && line.find("class=BrowserNativeWidgetWindow") != std::string::npos) f.browserWindowOrders++;
  }
  f.browserWindowsBefore = Count(before, "BrowserNativeWidgetWindow{");
  f.browserWindowsAfter = Count(after, "BrowserNativeWidgetWindow{");
  dialog = Count(after, "NativeWidgetMacNSWindow{vis=1") > 0;  // old runs recorded no dialog line; the after snapshot shows it
  f.dialogSeen = dialog;
  std::string why;
  const bool ok = InstallNoWindowOk(f, &why);
  std::cout << (ok ? "RULE PASS" : "RULE FAIL") << " browser-windows " << f.browserWindowsBefore << "->" << f.browserWindowsAfter << " guard-hits " << f.browserWindowOrders << " dialog " << dialog << " | " << why << "\n";
  if (std::string(argv[2]) == "fail" && why.find("browser-window") == std::string::npos) { std::cout << "RULE BUG the stock run must fail on the browser-window clause\n"; return 1; }
  return (ok ? "pass" : "fail") == std::string(argv[2]) ? 0 : 1;
}
