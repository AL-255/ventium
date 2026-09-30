#!/usr/bin/env python3
"""Host-only regression of the real leaf runner's RED/GREEN classifier.

Never execute the build or DUT prefix. Fixtures model captured log signatures,
not IDE behavior; the hardware gate remains run-pio-irq-gate.sh.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "verif/ide/run-pio-irq-gate.sh"
ANCHOR = 'if [[ "${EXPECT_RED:-0}" == 1 ]]; then\n'
RED = """IDE-READ-EXTRA-IRQ single-read-no-second-completion-irq irq=1 edges=2 status=50 count=256 request=0
IDE-READ-EXTRA-IRQ multi-read-one-irq-per-block irq=1 edges=3 status=50 count=256 request=0
IDE-READ-EXTRA-IRQ read-multiple-no-second-final-irq irq=1 edges=3 status=50 count=256 request=0
IDE-READ-EXTRA-IRQ identify-no-second-final-irq irq=1 edges=2 status=50 count=256 request=0
IDE-PIO-IRQ-RESULT checks=2623 irq_errors=4 control_errors=0
%Fatal: Assertion failed: IDE-PIO-IRQ-READ-RED
"""
GREEN = """IDE-PIO-IRQ-RESULT checks=2623 irq_errors=0 control_errors=0
IDE-PIO-IRQ-GATE-OK
"""


class ClassifierTest(unittest.TestCase):
    def test_actual_runner_tail(self):
        runner_bytes = RUNNER.read_bytes()
        text = runner_bytes.decode()
        self.assertEqual(text.count(ANCHOR), 1, "classifier layout changed")
        tail = ANCHOR + text.split(ANCHOR, 1)[1]
        self.assertNotIn("verilator", tail)
        self.assertNotIn("timeout", tail)
        cases = [
            ("known-red", RED, 1, 133, True),
            ("green", GREEN, 0, 0, True),
            ("red-wrong-mode", RED, 0, 133, False),
            ("green-wrong-mode", GREEN, 1, 0, False),
            ("red-success-exit", RED, 1, 0, False),
            ("red-timeout", RED, 1, 124, False),
            ("red-killed", RED, 1, 137, False),
            ("green-failed-exit", GREEN, 0, 133, False),
            ("missing-irq", RED.replace("irq=1 edges=2", "irq=0 edges=0", 1), 1, 133, False),
            ("bad-red-count", RED.replace("checks=2623", "checks=2622"), 1, 133, False),
            ("bad-green-count", GREEN.replace("checks=2623", "checks=2622"), 0, 0, False),
            ("extra-irq-failure", RED + RED.splitlines()[0] + "\n", 1, 133, False),
            ("control-failure", RED + "IDE-CONTROL-FAIL unexpected\n", 1, 133, False),
            ("missing-log", None, 1, 133, False),
        ]
        scratch = ROOT / "verif/ide/obj_dir_pio_irq_scratch"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="classifier-host.", dir=scratch) as directory:
            out = Path(directory)
            for name, log, expected_red, rc, should_accept in cases:
                with self.subTest(case=name):
                    log_path = out / "run.log"
                    if log is None:
                        log_path.unlink(missing_ok=True)
                    else:
                        log_path.write_text(log)
                    env = dict(os.environ, OUT=str(out), EXPECT_RED=str(expected_red),
                               CLASSIFIER_RC=str(rc))
                    result = subprocess.run(
                        ["bash", "-c", 'set -euo pipefail\nrc="$CLASSIFIER_RC"\n' + tail],
                        env=env, capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode == 0, should_accept,
                                     result.stdout + result.stderr)
        self.assertEqual(RUNNER.read_bytes(), runner_bytes)


if __name__ == "__main__":
    unittest.main()
