#!/usr/bin/env python3
"""Host-only regression for Vivado's bounded build_scope profile.

The real launcher is copied into a temporary tree and runs only `/bin/true`.
Mock systemd commands record resource properties, so this neither contacts the
user manager nor starts Vivado, a compiler, or an FPGA flow.
"""

import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "build_scope.sh"


class VivadoLimitPolicyTests(unittest.TestCase):
    def run_scope(
        self, *, memory=None, swap=None, tasks=None, profile="vivado", unit=None,
        memory_available_kib=32 * 1024 * 1024,
        swap_free_kib=32 * 1024 * 1024, meminfo_text=None,
    ):
        if unit is None:
            unit = "ventium-vivado" if profile == "vivado" else "ventium-build-scope-test"
        with tempfile.TemporaryDirectory(prefix="ventium-build-scope-test-") as temp_name:
            temp = Path(temp_name)
            clone = temp / "tools" / "build_scope.sh"
            clone.parent.mkdir()
            meminfo = temp / "meminfo"
            meminfo.write_text(
                meminfo_text if meminfo_text is not None else
                f"MemAvailable: {memory_available_kib} kB\nSwapFree: {swap_free_kib} kB\n"
            )
            source = SCRIPT.read_text()
            self.assertIn("done < /proc/meminfo", source)
            source = source.replace("/proc/meminfo", str(meminfo))
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
        swap_cap="2G",
        memory_high=None,
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
            if memory_high is None:
                memory_high = "max"
            if memory_high != "missing":
                (leaf / "memory.high").write_text(f"{memory_high}\n")
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
                    + "\nscope_has_cap \"$1\" \"$2\" 48 \"$3\"\n",
                    "scope-cap-test",
                    cgroup_path,
                    memory_cap,
                    swap_cap,
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
        result, properties = self.run_scope(memory="999999999999999999999G", swap="999999999999999999999G")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            properties,
            ["MemoryMax=20G", "TasksMax=48", "KillMode=control-group", "MemorySwapMax=8G"],
        )
        self.assertIn("clamping Vivado MemoryMax", result.stderr)
        self.assertIn("clamping Vivado MemorySwapMax", result.stderr)

    def test_explicit_mapper_retry_keeps_ram_bounded_and_allows_more_swap(self):
        result, properties = self.run_scope(memory="18G", swap="8G")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(properties, [
            "MemoryMax=18G", "TasksMax=48", "KillMode=control-group", "MemorySwapMax=8G",
        ])

    def test_vivado_does_not_inject_soft_pressure_or_change_oomd_victims(self):
        result, properties = self.run_scope(memory="18G", swap="8G")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(p.startswith(("MemoryHigh=", "ManagedOOM")) for p in properties))

    def test_admission_memory_and_swap_reserve_boundaries(self):
        cases = (
            (20 * 1024**2, 12 * 1024**2, 0),
            (20 * 1024**2 - 1, 12 * 1024**2, 125),
            (20 * 1024**2, 12 * 1024**2 - 1, 125),
        )
        for mem_kib, swap_kib, expected in cases:
            with self.subTest(memory_available_kib=mem_kib, swap_free_kib=swap_kib):
                result, properties = self.run_scope(
                    memory="18G", swap="8G", memory_available_kib=mem_kib,
                    swap_free_kib=swap_kib,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                if expected:
                    self.assertEqual(properties, [])
                    self.assertIn("refusing Vivado", result.stderr)

    def test_disabled_swap_needs_no_host_swap_reserve(self):
        result, properties = self.run_scope(memory="12G", swap="0", swap_free_kib=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MemorySwapMax=0", properties)

    def test_missing_or_malformed_host_memory_fails_closed(self):
        for sample in (
            "", "MemAvailable: 33554432 kB\n", "SwapFree: 33554432 kB\n",
            "MemAvailable: bad kB\nSwapFree: 33554432 kB\n",
            "MemAvailable: 33554432 MB\nSwapFree: 33554432 kB\n",
            "MemAvailable: 33554432 kB unexpected\nSwapFree: 33554432 kB\n",
        ):
            with self.subTest(sample=sample):
                result, properties = self.run_scope(meminfo_text=sample)
                self.assertEqual(result.returncode, 125, result.stderr)
                self.assertEqual(properties, [])

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
                result, properties = self.run_scope(profile=profile, unit=unit, meminfo_text="")
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

    def test_scope_has_cap_uses_the_explicit_selected_swap_limit(self):
        accepted = self.run_scope_has_cap(swap_cap="8G", swap_max=8 * 1024**3)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        oversized = self.run_scope_has_cap(swap_cap="8G", swap_max=9 * 1024**3)
        self.assertNotEqual(oversized.returncode, 0, oversized.stderr)

    def test_scope_has_cap_requires_unthrottled_vivado_soft_boundary(self):
        accepted = self.run_scope_has_cap(memory_high="max")
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        for limit in (20 * 1024**3 * 9 // 10, 20 * 1024**3, "missing", "", "bad", "infinity"):
            with self.subTest(memory_high=limit):
                result = self.run_scope_has_cap(memory_high=limit)
                self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_nested_active_scope_requires_unthrottled_caps_and_inherited_lock(self):
        # Execute the actual nesting and lock-attestation functions, not only
        # the leaf cap helper. No real manager/cgroup/production lock is used.
        source = SCRIPT.read_text()
        names = (
            "size_to_bytes", "vivado_size_status", "vivado_memory_limit",
            "vivado_swap_limit", "scope_has_cap", "scope_required_limits",
            "scope_holds_lock", "scope_is_active",
        )
        functions = "\n\n".join(self.extract_function(source, name) for name in names)
        functions = functions.replace(
            'cgroup_root="/sys/fs/cgroup${cgroup_path}"',
            'cgroup_root="${BUILD_SCOPE_TEST_CGROUP_ROOT}${cgroup_path}"', 1,
        ).replace("/proc/self/cgroup", '"${BUILD_SCOPE_TEST_PROC_CGROUP}"')
        self.assertNotIn("/sys/fs/cgroup", functions)
        self.assertNotIn("/proc/self/cgroup", functions)
        cases = (("max", True, 0), ("max", False, 1), (16 * 1024**3, True, 1))
        for high, inherited_lock, expected in cases:
            with self.subTest(memory_high=high, inherited_lock=inherited_lock):
                with tempfile.TemporaryDirectory(prefix="ventium-build-scope-nested-test-") as temp_name:
                    # TMPDIR can be the external-storage symlink. The real
                    # lock attestor canonicalizes /proc/self/fd targets, so
                    # give this PRIVATE fixture its canonical lock path too.
                    temp = Path(temp_name).resolve()
                    leaf = temp / "cgroup" / "app.slice" / "ventium-vivado.scope"
                    leaf.mkdir(parents=True)
                    for name, value in (
                        ("memory.max", 18 * 1024**3), ("pids.max", 48),
                        ("memory.swap.max", 8 * 1024**3), ("memory.high", high),
                    ):
                        (leaf / name).write_text(f"{value}\n")
                    proc_cgroup = temp / "proc-cgroup"
                    proc_cgroup.write_text("0::/app.slice/ventium-vivado.scope\n")
                    lock_path = temp / "scope.lock"
                    env = os.environ.copy()
                    env.update(
                        BUILD_SCOPE_TEST_CGROUP_ROOT=str(temp / "cgroup"),
                        BUILD_SCOPE_TEST_PROC_CGROUP=str(proc_cgroup),
                        BUILD_SCOPE_TEST_LOCK=str(lock_path),
                        VENTIUM_BUILD_SCOPE_ACTIVE="1", VENTIUM_BUILD_SCOPE_UNIT="ventium-vivado",
                        VENTIUM_VIVADO_MEMORY_MAX="18G", VENTIUM_VIVADO_MEMORY_SWAP_MAX="8G",
                    )
                    script = (
                        'set -euo pipefail\nvivado_memory_max=20G\nvivado_swap_default=2G\n'
                        'vivado_swap_max=8G\nvivado_tasks_max=48\n'
                        'lock_path="$BUILD_SCOPE_TEST_LOCK"\n' + functions + "\nscope_is_active\n"
                    )
                    with lock_path.open("w") as held_lock:
                        fcntl.flock(held_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        result = subprocess.run(
                            ["bash", "-c", script], env=env, text=True, capture_output=True,
                            pass_fds=(held_lock.fileno(),) if inherited_lock else (),
                        )
                    self.assertEqual(result.returncode, expected, result.stderr)

    def test_scope_has_cap_rejects_stale_smaller_inherited_memory_request(self):
        result = self.run_scope_has_cap(memory_cap="8G")
        self.assertNotEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
