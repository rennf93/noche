// Replays a recorded store run (docs/engine/evidence/b4-store-*.txt) through the install-no-window pass rule.
// usage: store_rule_test <evidence file> <expect: pass|fail>. The facts come from the PROBE lines of the run.
#include <fstream>
#include <iostream>
#include <string>
#include "../EngineProbe/store_rule.h"

static int Count(const std::string& s, const std::string& needle) {
  int n = 0;
  for (size_t p = s.find(needle); p != std::string::npos; p = s.find(needle, p + 1)) n++;
  return n;
}

int main(int argc, char** argv) {
  if (argc != 3) return 2;
  std::ifstream in(argv[1]);
  std::string line, before, after;
  // A failed Target.getTargets must fail the rule on its own, whatever the windows say.
  InstallFacts unchecked;
  unchecked.dialogSeen = true;
  unchecked.staleTabTargets = -1;
  if (InstallNoWindowOk(unchecked, nullptr)) { std::cout << "RULE BUG unanswered Target.getTargets passed\n"; return 1; }
  InstallFacts f;
  f.staleTabTargets = 0;  // the recorded runs predate the target query; the replay checks the window rule
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
  return (ok ? "pass" : "fail") == std::string(argv[2]) ? 0 : 1;
}
