#!/usr/bin/env python3
"""Test the real shell LTO policy without launching a scope or compiler."""

import os
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "tools/verilator_serial.sh"
BUNDLE = ("USER_CPPFLAGS=-flto=1", "USER_LDFLAGS=-flto=1", "AR=gcc-ar")


class SerialLtoPolicyTests(unittest.TestCase):
    def test_frontend_opt_is_separate_and_default_unchanged(self):
        for value in ("default", "3", "2", "", "default 3"):
            with self.subTest(value=value):
                result = subprocess.run(["make", "-C", str(ROOT / "verif/tb"), "-n",
                                         "rtl", f"VL_FRONTEND_OPT={value}"],
                                        capture_output=True, text=True)
                if value not in ("default", "3"):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("VL_FRONTEND_OPT", result.stderr)
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(bool(re.search(r"(?:^|\s)-O3(?:\s|$)", result.stdout)), value == "3")
                    self.assertIn("OPT_FAST=-O3", result.stdout)

    def policy(self, flags, profile="default"):
        text = WRAPPER.read_text()
        policy = text.split("# BEGIN serial LTO flag policy", 1)[1]
        policy = policy[policy.index("\n") + 1:].split("# END serial LTO flag policy.", 1)[0]
        script = "set -euo pipefail\n" + policy + "\n" + """
for flag in "$@"; do
    note_serial_lto_makeflag "$flag" || exit 2
    safe_makeflags "$flag" || exit 2
done
validate_serial_lto_makeflags || exit 2
"""
        env = dict(os.environ, VENTIUM_BUILD_SCOPE_PROFILE=profile,
                   script_dir=str(ROOT / "tools"))
        return subprocess.run(["bash", "-c", script, "policy", *flags],
                              env=env, capture_output=True, text=True)

    def test_defaults_and_existing_exact_flags_unchanged(self):
        for profile in ("default", "ipc_parallel", "ipc_parallel32"):
            with self.subTest(profile=profile):
                self.assertEqual(self.policy((), profile).returncode, 0)
                self.assertEqual(self.policy(("OPT_FAST=-O3", "OPT=-march=native"), profile).returncode, 0)
                self.assertEqual(self.policy((f"-f {ROOT}/verif/tb/model_input_snapshot.mk",), profile).returncode, 0)

    def test_serial_bundle_only_in_fixed_large_scope(self):
        self.assertEqual(self.policy(BUNDLE, "ipc_parallel32").returncode, 0)
        self.assertEqual(self.policy(tuple(reversed(BUNDLE)), "ipc_parallel32").returncode, 0)
        for profile in ("default", "ipc_parallel", "vivado", "unreviewed"):
            with self.subTest(profile=profile):
                self.assertEqual(self.policy(BUNDLE, profile).returncode, 2)

    def test_partial_and_duplicate_bundles_fail_closed(self):
        for flags in ((BUNDLE[0],), (BUNDLE[1],), (BUNDLE[2],), BUNDLE[:2],
                      BUNDLE[1:], (BUNDLE[0], BUNDLE[2]), (*BUNDLE, BUNDLE[0]),
                      (*BUNDLE, BUNDLE[1]), (*BUNDLE, BUNDLE[2])):
            with self.subTest(flags=flags):
                self.assertEqual(self.policy(flags, "ipc_parallel32").returncode, 2)

    def test_no_general_make_or_lto_escape(self):
        for flag in ("USER_CPPFLAGS=-flto=auto", "USER_LDFLAGS=-flto=32",
                     "OPT=-march=native -flto=1", "USER_LDFLAGS=-flto=jobserver",
                     "USER_LDFLAGS=-O3 -flto=1 -fuse-linker-plugin", "AR=gcc-ar-15",
                     "MAKEFLAGS=-j32", "-f /tmp/unreviewed.mk"):
            with self.subTest(flag=flag):
                self.assertEqual(self.policy((flag,), "ipc_parallel32").returncode, 2)

    def test_make_knob_rejects_bad_value_and_profile_without_compiling(self):
        for value, profile in (("2", "ipc_parallel32"), ("1", "default"),
                               ("1", "ipc_parallel")):
            with self.subTest(value=value, profile=profile):
                result = subprocess.run(["make", "-C", str(ROOT / "verif/tb"), "-n",
                                         "rtl", f"VL_LTO_SERIAL={value}",
                                         f"VENTIUM_BUILD_SCOPE_PROFILE={profile}"],
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("VL_LTO_SERIAL", result.stderr)
        result = subprocess.run(["make", "-C", str(ROOT / "verif/tb"), "-n", "rtl",
                                 "VL_LTO_SERIAL=1", "VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for flag in BUNDLE:
            self.assertIn("-MAKEFLAGS " + flag, result.stdout)


if __name__ == "__main__":
    unittest.main()
