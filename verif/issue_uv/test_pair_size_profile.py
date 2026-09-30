#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Compile/exhaust the actual optional V-read size mux, not a copied mux.

Five small Verilator leaves run under the shared default resource scope with a
480-second overall limit. Inactive optional declarations are deliberately
absent: preprocessing and strict compilation must both prove no dangling PRIME
or REGMEM symbols. Generated evidence is retained only under mktemp /tmp.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CONFIGS = (("byte_off_raw", ()),
           ("byte_off_prime", ("VEN_P54_DUAL_LOAD_PRIME",)),
           ("byte_on_raw", ("VEN_P54_DUAL_BYTE_LOAD_PAIR",)),
           ("byte_on_prime", ("VEN_P54_DUAL_BYTE_LOAD_PAIR", "VEN_P54_DUAL_LOAD_PRIME")),
           ("byte_on_regmem", ("VEN_P54_DUAL_BYTE_LOAD_PAIR", "VEN_P54_DUAL_LOAD_PRIME", "VEN_P54_REGMEM_PRIME")))


def scoped_run(command, **kwargs):
    # Python otherwise closes FD9 even inside the real scope. Preserve only
    # the verified lock-path descriptors so nested wrappers can independently
    # prove containment; never replace the guard with an environment marker.
    lock_fds = []
    for fd in Path("/proc/self/fd").iterdir():
        try:
            if fd.resolve(strict=True) == Path("/tmp/ventium-heavy-build.lock"):
                lock_fds.append(int(fd.name))
        except (OSError, ValueError):
            pass
    return subprocess.run(command, pass_fds=tuple(lock_fds), **kwargs)


def production_mux(source):
    first = source.index("  assign mem_pair_size_log2 = ")
    start = source.rfind("\n`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR\n", 0, first)
    if start < 0:
        raise ValueError("missing production byte-pair conditional")
    depth, block = 0, []
    for line in source[start + 1:].splitlines(keepends=True):
        block.append(line)
        if re.match(r"\s*`ifn?def\b", line):
            depth += 1
        elif re.match(r"\s*`endif\b", line):
            depth -= 1
            if depth == 0:
                break
    result = "".join(block)
    if depth or result.count("assign mem_pair_size_log2 =") != 2:
        raise ValueError("production size-mux extent changed; inspect extraction")
    return result


BODY = r"""`timescale 1ns/1ps
module tb_pair_size_profile;
  typedef struct packed {logic w8;} width_t;
  logic pipe_v_pair_request;
  width_t pipe_v_eff;
  logic [3:0] mem_pair_size_log2;
`ifdef VEN_P54_DUAL_LOAD_PRIME
  logic mc_prime_v_request;
  width_t mc_query_v;
`ifdef VEN_P54_REGMEM_PRIME
  logic regmem_prime_v_request;
`endif
`endif
@MUX@
  int checked=0;
  initial begin
    for (int req=0; req<8; req++) begin
      for (int widths=0; widths<4; widths++) begin
        bit selected_byte;
        logic [3:0] expected;
        pipe_v_pair_request=1'(req);
        pipe_v_eff.w8=1'(widths);
`ifdef VEN_P54_DUAL_LOAD_PRIME
        mc_prime_v_request=1'(req>>1);
        mc_query_v.w8=1'(widths>>1);
`ifdef VEN_P54_REGMEM_PRIME
        regmem_prime_v_request=1'(req>>2);
`endif
`endif
        selected_byte=0;
`ifdef VEN_P54_DUAL_BYTE_LOAD_PAIR
        // Protocol oracle: predecessor owner takes priority over live V.
`ifdef VEN_P54_DUAL_LOAD_PRIME
        if ((req&2)!=0
`ifdef VEN_P54_REGMEM_PRIME
            || (req&4)!=0
`endif
           ) selected_byte=(widths&2)!=0;
        else
`endif
          selected_byte=(req&1)!=0 && (widths&1)!=0;
`endif
        expected=selected_byte ? 4'b0000 : 4'b1000;
        #1;
        if (mem_pair_size_log2 !== expected)
          $fatal(1,"size owner mismatch req=%0d widths=%0d got=%0h expected=%0h",
                 req,widths,mem_pair_size_log2,expected);
        checked++;
      end
    end
    if (checked!=32) $fatal(1,"incomplete size-mux coverage");
    $display("PAIR-SIZE-PROFILE-OK checks=%0d",checked);
    $finish;
  end
endmodule
"""


class PairSizeProfileTests(unittest.TestCase):
    def test_actual_production_mux_profiles(self):
        self.assertEqual(scoped_run([str(ROOT / "tools/build_scope.sh"), "--is-active"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode, 0,
                         "run this RTL leaf inside the shared actual build scope")
        source = (ROOT / "rtl/core/core.sv").read_text()
        mux = production_mux(source)
        out = Path(tempfile.mkdtemp(prefix="ventium-pair-size-profile-", dir="/tmp"))
        print(f"Artifacts: {out}", flush=True)
        receipt = {"core_sha256": hashlib.sha256(source.encode()).hexdigest(),
                   "mux_sha256": hashlib.sha256(mux.encode()).hexdigest(), "profiles": []}
        rtl = out / "tb_pair_size_profile.sv"
        rtl.write_text(BODY.replace("@MUX@", mux))
        wrapper = str(ROOT / "tools/verilator_serial.sh")
        for name, defines in CONFIGS:
            with self.subTest(profile=name):
                directory = out / name
                directory.mkdir()
                flags = [f"+define+{define}" for define in defines]
                pp = scoped_run(["timeout", "--kill-after=5s", "20s", wrapper,
                                     "-E", "-sv", *flags, str(rtl)],
                                    capture_output=True, text=True, check=True)
                (directory / "preprocessed.sv").write_text(pp.stdout)
                for symbol, enabled in (("mc_prime_v_request", "VEN_P54_DUAL_LOAD_PRIME" in defines),
                                         ("mc_query_v", "VEN_P54_DUAL_LOAD_PRIME" in defines),
                                         ("regmem_prime_v_request", "VEN_P54_REGMEM_PRIME" in defines)):
                    self.assertEqual(bool(re.search(r"\b" + symbol + r"\b", pp.stdout)), enabled, symbol)
                command = ["timeout", "--signal=TERM", "--kill-after=5s", "75s", wrapper,
                           "--binary", "--timing", "--assert", "-j", "2", "-sv", "-Wall",
                           "-Wno-fatal", "-Wno-UNUSED", "-Werror-IMPLICIT", "-Werror-PINMISSING",
                           "-Werror-UNDRIVEN", "-Werror-MULTIDRIVEN", "-Werror-LATCH",
                           "-Werror-UNOPTFLAT", "--top-module", "tb_pair_size_profile",
                           "--Mdir", str(directory / "obj"), *flags, str(rtl)]
                with (directory / "build.log").open("w") as log:
                    built = scoped_run(command, stdout=log, stderr=subprocess.STDOUT)
                self.assertEqual(built.returncode, 0, (directory / "build.log").read_text()[-5000:])
                run = scoped_run(["timeout", "--kill-after=5s", "5s",
                                      str(directory / "obj/Vtb_pair_size_profile")],
                                     capture_output=True, text=True, check=True)
                (directory / "run.log").write_text(run.stdout + run.stderr)
                self.assertIn("PAIR-SIZE-PROFILE-OK checks=32", run.stdout)
                receipt["profiles"].append({"name": name, "defines": defines, "checks": 32})
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print("PAIR-SIZE-ALL-PROFILES-OK profiles=5 checks=160", flush=True)


if __name__ == "__main__":
    # Bound the entire preprocessor/compiler/simulation tree, not just each
    # compiler process. Default scope rewrites -j2 to one compiler (<=two).
    scope = str(ROOT / "tools/build_scope.sh")
    if scoped_run([scope, "--is-active"], stdout=subprocess.DEVNULL,
                  stderr=subprocess.DEVNULL).returncode:
        if os.environ.get("VENTIUM_BUILD_SCOPE_ACTIVE") == "1":
            raise SystemExit("existing scope failed actual lock/cgroup proof; refusing recursive re-entry")
        os.environ["VENTIUM_BUILD_SCOPE_PROFILE"] = "default"
        os.environ.pop("VENTIUM_BUILD_SCOPE_UNIT", None)
        os.execv(scope, [scope, "--", "timeout", "--signal=TERM", "--kill-after=10s", "480s",
                        sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]])
    unittest.main()
