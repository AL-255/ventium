#!/usr/bin/env python3
"""Host-only regression for Vivado's bounded build_scope profile.

The real launcher is copied into a temporary tree and runs only `/bin/true`.
Mock systemd commands record resource properties, so this neither contacts the
user manager nor starts Vivado, a compiler, or an FPGA flow.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "build_scope.sh"


class VivadoLimitPolicyTests(unittest.TestCase):
    def run_scope(self, *, memory=None, swap=None, tasks=None):
        with tempfile.TemporaryDirectory(prefix="ventium-build-scope-test-") as temp_name:
            temp = Path(temp_name)
            clone = temp / "tools" / "build_scope.sh"
            clone.parent.mkdir()
            source = SCRIPT.read_text()
            source = source.replace(
                'lock_path="/tmp/ventium-heavy-build.lock"',
                f'lock_path="{temp / "scope.lock"}"',
                1,
            ).replace(
                'scope_marker_root="/tmp/ventium-build-scope"',
                f'scope_marker_root="{temp / "markers"}"',
                1,
            )
            clone.write_text(source)
            clone.chmod(0o755)

            mock_bin = temp / "bin"
            mock_bin.mkdir()
            capture = temp / "systemd-properties.txt"
            (mock_bin / "systemd-run").write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                ": \"${BUILD_SCOPE_TEST_CAPTURE:?}\"\n"
                "while [ \"$#\" -gt 0 ]; do\n"
                "    case \"$1\" in\n"
                "        -p) printf '%s\\n' \"$2\" >> \"$BUILD_SCOPE_TEST_CAPTURE\"; shift 2 ;;\n"
                "        --) shift; break ;;\n"
                "        *) shift ;;\n"
                "    esac\n"
                "done\n"
                "exec \"$@\"\n"
            )
            (mock_bin / "systemctl").write_text(
                "#!/usr/bin/env bash\n"
                "# The result marker is written synchronously by the mocked scope.\n"
                "exit 0\n"
            )
            for command in (mock_bin / "systemd-run", mock_bin / "systemctl"):
                command.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = f"{mock_bin}:{env['PATH']}"
            env["BUILD_SCOPE_TEST_CAPTURE"] = str(capture)
            env["VENTIUM_BUILD_SCOPE_UNIT"] = "ventium-vivado"
            env["VENTIUM_BUILD_SCOPE_PROFILE"] = "vivado"
            env["VENTIUM_BUILD_TMPDIR"] = str(temp / "build-tmp")
            for name, value in (
                ("VENTIUM_BUILD_SCOPE_ACTIVE", None),
                ("VENTIUM_VIVADO_MEMORY_MAX", memory),
                ("VENTIUM_VIVADO_MEMORY_SWAP_MAX", swap),
                ("VENTIUM_VIVADO_TASKS_MAX", tasks),
            ):
                if value is None:
                    env.pop(name, None)
                else:
                    env[name] = value

            result = subprocess.run(
                ["bash", str(clone), "--", "/bin/true"],
                cwd=temp,
                env=env,
                capture_output=True,
                text=True,
            )
            properties = capture.read_text().splitlines() if capture.exists() else []
            return result, properties

    def test_defaults_keep_reviewed_ceilings(self):
        result, properties = self.run_scope()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            properties,
            ["MemoryMax=20G", "TasksMax=32", "KillMode=control-group", "MemorySwapMax=2G"],
        )

    def test_lower_memory_and_swap_are_applied_but_tasks_stay_fixed(self):
        result, properties = self.run_scope(memory="12G", swap="1G", tasks="128")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            properties,
            ["MemoryMax=12G", "TasksMax=32", "KillMode=control-group", "MemorySwapMax=1G"],
        )
        self.assertIn("forcing reviewed Vivado TasksMax=32", result.stderr)

    def test_oversized_and_huge_requests_are_visibly_clamped(self):
        result, properties = self.run_scope(memory="999999999999999999999G", swap="3G")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            properties,
            ["MemoryMax=20G", "TasksMax=32", "KillMode=control-group", "MemorySwapMax=2G"],
        )
        self.assertIn("clamping Vivado MemoryMax", result.stderr)
        self.assertIn("clamping Vivado MemorySwapMax", result.stderr)

    def test_zero_memory_rejects_before_a_scope_is_created(self):
        result, properties = self.run_scope(memory="0")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(properties, [])
        self.assertIn("VENTIUM_VIVADO_MEMORY_MAX must be positive", result.stderr)

    def test_zero_swap_is_explicitly_disabled(self):
        result, properties = self.run_scope(memory="12G", swap="0M")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MemorySwapMax=0", properties)


if __name__ == "__main__":
    unittest.main()
