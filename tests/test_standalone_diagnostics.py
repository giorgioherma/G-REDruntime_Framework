import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1] / "r6/scripts/G-RedRuntime"

class StandaloneDiagnostics(unittest.TestCase):
    def test_no_optional_global_logging_headers(self):
        for path in ROOT.rglob("*.reds"):
            source = path.read_text(encoding="utf-8-sig")
            self.assertIsNone(re.search(r"\b(?:Log(?:Channel)?(?:Warning|Error)?|FTLog(?:Warning|Error)?|Trace(?:ToString)?)\s*\(", source), str(path))

    def test_manual_diagnostics_return_information(self):
        core = (ROOT / "Core/Runtime.reds").read_text()
        player = (ROOT / "Input/PlayerExtensions.reds").read_text()
        self.assertIn("func DumpDiagnostics() -> String", core)
        for field in ("schedulerWakeups", "schedulerJobRuns", "eventPublishes", "eventDeliveries", "inputEventsSeen", "inputDeliveries", "hookDispatches", "hookDeliveries", "stateCacheHits", "stateCacheMisses", "GetActiveInterestCount", "GetSnapshotCount", "GetDeliveryCount"):
            self.assertIn(field, core.split("func DumpDiagnostics()", 1)[1])
        self.assertIn("return report;", core)
        self.assertIn("return runtime.DumpDiagnostics();", player)
        self.assertIn('return "G-RedRuntime is not available";', player)

    def test_system_requests_handler_uses_vanilla_resolution(self):
        source = (ROOT / "State/StateCache.reds").read_text()
        self.assertNotIn("GameInstance.GetSystemRequestsHandler(", source)
        self.assertIn("this.m_systemRequestsHandler = new inkMenuScenario().GetSystemRequestsHandler();", source)
