"""Header generation must precede canonical AND isolated harness compilation."""
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class SnapshotMakeTests(unittest.TestCase):
    def test_each_generated_user_object_has_snapshot_dependency(self):
        for harness in ("tb_main", "tb_private_candidate"):
            with self.subTest(harness=harness), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                # A stand-in producer checks make ordering without Verilator or
                # C++ compilation. The real included file supplies dependencies.
                (root / "Makefile").write_text(
                    f"VM_USER_CLASSES := {harness} memmodel\n"
                    f"include {REPO}/verif/tb/model_input_snapshot.mk\n"
                    "Vventium_top.h:\n\ttouch $@\n"
                    "model_input_snapshot.h:\n\ttouch $@\n"
                    "%.o:\n\ttest -f model_input_snapshot.h\n\ttouch $@\n")
                result = subprocess.run(
                    ["make", "--no-print-directory", "-j32", f"{harness}.o", "memmodel.o"],
                    cwd=root, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((root / f"{harness}.o").exists())
                self.assertTrue((root / "memmodel.o").exists())


if __name__ == "__main__":
    unittest.main()
