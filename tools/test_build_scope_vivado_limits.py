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
    def run_scope(self, *, memory=None, swap=None, tasks=None, profile="vivado", unit=None):
        if unit is None:
            unit = "ventium-vivado" if profile == "vivado" else "ventium-build-scope-test"
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
            env["VENTIUM_BUILD_SCOPE_UNIT"] = unit
            env["VENTIUM_BUILD_SCOPE_PROFILE"] = profile
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

    @staticmethod
    def extract_function(source, name):
        """Extract one top-level shell function without sourcing the launcher."""
        start = source.find(f"{name}() {{\n")
        if start < 0:
            raise AssertionError(f"missing {name}() in {SCRIPT}")
        end = source.find("\n}\n", start)
        if end < 0:
            raise AssertionError(f"unterminated {name}() in {SCRIPT}")
        return source[start : end + 3]

    def run_scope_has_cap(
        self,
        *,
        cgroup_path="/scope",
        memory_max=20 * 1024 * 1024 * 1024,
        pids_max="48",
        swap_max=2 * 1024 * 1024 * 1024,
        parent_memory_max=None,
        memory_cap="20G",
    ):
        """Run extracted cap logic against a private fake cgroup filesystem.

        This deliberately rewrites the function's `/sys/fs/cgroup` root into a
        TemporaryDirectory.  It never reads or mutates the host cgroup tree.
        """
        source = SCRIPT.read_text()
        functions = "\n\n".join(
            self.extract_function(source, name) for name in ("size_to_bytes", "scope_has_cap")
        )
        old_root = 'cgroup_root="/sys/fs/cgroup${cgroup_path}"'
        new_root = 'cgroup_root="${BUILD_SCOPE_TEST_CGROUP_ROOT}${cgroup_path}"'
        self.assertIn(old_root, functions)
        functions = functions.replace(old_root, new_root, 1)
        self.assertNotIn("/sys/fs/cgroup", functions)

        with tempfile.TemporaryDirectory(prefix="ventium-build-scope-cap-test-") as temp_name:
            fake_root = Path(temp_name) / "cgroup"
            leaf = fake_root / cgroup_path.lstrip("/")
            leaf.mkdir(parents=True)
            (leaf / "memory.max").write_text(f"{memory_max}\n")
            (leaf / "pids.max").write_text(f"{pids_max}\n")
            (leaf / "memory.swap.max").write_text(f"{swap_max}\n")
            if parent_memory_max is not None:
                parent = leaf.parent
                (parent / "memory.max").write_text(f"{parent_memory_max}\n")

            env = os.environ.copy()
            env["BUILD_SCOPE_TEST_CGROUP_ROOT"] = str(fake_root)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    "set -euo pipefail\n"
                    + functions
                    + "\nscope_has_cap \"$1\" \"$2\" 48 2G\n",
                    "scope-cap-test",
                    cgroup_path,
                    memory_cap,
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            return result

    def test_defaults_keep_reviewed_ceilings(self):
        result, properties = self.run_scope()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            properties,
            ["MemoryMax=20G", "TasksMax=48", "KillMode=control-group", "MemorySwapMax=2G"],
        )

    def test_lower_memory_and_swap_are_applied_but_tasks_stay_fixed(self):
        result, properties = self.run_scope(memory="12G", swap="1G", tasks="128")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            properties,
            ["MemoryMax=12G", "TasksMax=48", "KillMode=control-group", "MemorySwapMax=1G"],
        )
        self.assertIn("forcing reviewed Vivado TasksMax=48", result.stderr)

    def test_low_task_request_is_also_ignored(self):
        result, properties = self.run_scope(memory="12G", swap="1G", tasks="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            properties,
            ["MemoryMax=12G", "TasksMax=48", "KillMode=control-group", "MemorySwapMax=1G"],
        )
        self.assertIn("forcing reviewed Vivado TasksMax=48", result.stderr)

    def test_oversized_and_huge_requests_are_visibly_clamped(self):
        result, properties = self.run_scope(memory="999999999999999999999G", swap="3G")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            properties,
            ["MemoryMax=20G", "TasksMax=48", "KillMode=control-group", "MemorySwapMax=2G"],
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

    def test_nonvivado_profiles_are_unchanged(self):
        cases = (
            ("default", "ventium-build-scope-test", ["MemoryMax=4G", "TasksMax=64", "KillMode=control-group"]),
            ("ipc_parallel", "ventium-ipc-parallel", ["MemoryMax=10G", "TasksMax=64", "KillMode=control-group"]),
            ("ipc_parallel32", "ventium-ipc-parallel32", ["MemoryMax=16G", "TasksMax=128", "KillMode=control-group"]),
        )
        for profile, unit, expected in cases:
            with self.subTest(profile=profile):
                result, properties = self.run_scope(profile=profile, unit=unit)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(properties, expected)

    def test_scope_has_cap_accepts_explicit_task_limits_at_or_below_48(self):
        for pids_max in ("32", "36", "48"):
            with self.subTest(pids_max=pids_max):
                result = self.run_scope_has_cap(pids_max=pids_max)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_scope_has_cap_rejects_task_limits_above_48_or_unlimited(self):
        for pids_max in ("49", "max"):
            with self.subTest(pids_max=pids_max):
                result = self.run_scope_has_cap(pids_max=pids_max)
                self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_scope_has_cap_requires_explicit_numeric_leaf_memory_cap(self):
        explicit = self.run_scope_has_cap(memory_max=20 * 1024 * 1024 * 1024)
        self.assertEqual(explicit.returncode, 0, explicit.stderr)

        inherited = self.run_scope_has_cap(
            cgroup_path="/parent/scope",
            memory_max="max",
            parent_memory_max=8 * 1024 * 1024 * 1024,
        )
        self.assertNotEqual(inherited.returncode, 0, inherited.stderr)

    def test_scope_has_cap_rejects_swap_above_reviewed_ceiling(self):
        result = self.run_scope_has_cap(swap_max=3 * 1024 * 1024 * 1024)
        self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_scope_has_cap_rejects_stale_smaller_inherited_memory_request(self):
        result = self.run_scope_has_cap(memory_cap="8G")
        self.assertNotEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
