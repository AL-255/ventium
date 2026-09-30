#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Exercise the actual PC shim's cached-store policy, not a copied RTL model.

Run through tools/build_scope.sh (two compiler jobs, <=480 seconds). Generated
sources and the exact source/hash receipt stay under the validated, non-symlink
verif/l1/obj_dir_store_policy_scratch root-filesystem directory. Compiler TMPDIR
is explicitly rooted there too, rather than using quota-limited /tmp or the
external-volume repo tmp symlink. The production function and BOTH independent
U/V call sites are extracted verbatim. This is an address-shaping leaf; the
actual L1/AXI/ao486-L2 gate checks mutation, acceptance, all strobes, crossing
lines and posted-policy changes separately.
"""
import hashlib
import json
import os
from pathlib import Path
import random
import re
import signal
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ao486-sim/ven/ven_ao486_shim.sv"


def lock_fds():
    result = []
    for fd in Path("/proc/self/fd").iterdir():
        try:
            if fd.resolve(strict=True) == Path("/tmp/ventium-heavy-build.lock"):
                result.append(int(fd.name))
        except (OSError, ValueError):
            pass
    return tuple(result)


def command(argv, timeout, log=None):
    # Keep the inherited real lock, and kill the whole compiler tree on a
    # timeout; subprocess.run's immediate-child kill is not sufficient.
    with subprocess.Popen(argv, cwd=ROOT, pass_fds=lock_fds(),
                          start_new_session=True, stdout=log,
                          stderr=subprocess.STDOUT if log else None) as proc:
        try:
            status = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=10)
            raise
        if status:
            raise subprocess.CalledProcessError(status, argv)


def production_parts(source):
    match = re.search(r"    function automatic logic \[3:0\] pc_store_update_mask\(.*?"
                      r"    endfunction\n", source, re.S)
    if match is None or source.count("function automatic logic [3:0] pc_store_update_mask(") != 1:
        raise ValueError("inspect production function extent before updating extraction")
    calls = []
    for name in ("store_policy", "store_pair_policy"):
        call = re.search(r"    assign " + name + r"_update_mask = "
                         r"pc_store_update_mask\(" + name + r"_addr, a20_enable\);\n", source)
        if call is None:
            raise ValueError(f"missing independent production {name} call site")
        calls.append(call[0])
    return match[0], "".join(calls)


def addresses():
    # Test every high-nibble fold, A20 alias, ROM/UMA/shared boundary and the
    # DWORD whose producer-byte addition wraps at the top of 32-bit space.
    points = (0, 0xC0000, 0xCE000, 0xD0000, 0xE0000, 0xF0000, 0x100000,
              0x1C0000, 0x1CE000, 0x1D0000, 0x1E0000, 0x1F0000, 0x200000,
              0xFFFFFF0, 0x10000000, 0xFFFFFFFF)
    result = {(((point + delta) & 0x0FFFFFFF) | (high << 28))
              for point in points for delta in range(-8, 9) for high in range(16)}
    rng = random.Random(0xC0620)
    result.update(rng.getrandbits(32) for _ in range(2048))
    return sorted(result)


DRIVER = r'''#include "Vstore_policy_shape.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
static const uint32_t addrs[] = { @ADDRESSES@ };
static uint8_t oracle(uint32_t addr, bool a20) {
    uint8_t result = 0;
    // Independent region-selector oracle: C0000-FFFFF is 256-KiB region 3.
    // Addition is uint32_t first; folding/A20 happen to each backend byte.
    const uint32_t keep = a20 ? 0x0fffffffU : 0x0fefffffU;
    for (unsigned i=0; i<4; ++i) {
        const uint32_t backend = uint32_t(addr+i) & keep;
        if ((backend >> 18) != 3U) result |= uint8_t(1U << i);
    }
    return result;
}
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vstore_policy_shape dut;
    unsigned checked=0;
    const unsigned n=sizeof(addrs)/sizeof(addrs[0]);
    for (unsigned j=0; j<n; ++j) {
        for (unsigned a20=0; a20<2; ++a20) {
            const uint32_t u=addrs[j], v=addrs[(j*17U+1U)%n];
            dut.store_policy_addr=u;
            dut.store_pair_policy_addr=v;
            dut.a20_enable=a20;
            dut.eval();
            const uint8_t eu=oracle(u,a20), ev=oracle(v,a20);
            for (unsigned strobe=0; strobe<16; ++strobe) {
                if ((dut.store_policy_update_mask & strobe) != (eu & strobe) ||
                    (dut.store_pair_policy_update_mask & strobe) != (ev & strobe)) {
                    std::fprintf(stderr,"policy addr=%08x pair=%08x a20=%u strobe=%x got=%x/%x expected=%x/%x\n",
                                 u,v,a20,strobe,dut.store_policy_update_mask,
                                 dut.store_pair_policy_update_mask,eu,ev);
                    return 1;
                }
                ++checked;
            }
        }
    }
    std::printf("STORE-POLICY-SHAPE-OK addresses=%u checks=%u\n",n,checked);
    dut.final();
    return 0;
}
'''


def main():
    subprocess.run([str(ROOT / "tools/build_scope.sh"), "--is-active"],
                   pass_fds=lock_fds(), check=True)
    scratch = ROOT / "verif/l1/obj_dir_store_policy_scratch"
    if scratch.resolve() != scratch:
        raise ValueError(f"refusing symlinked policy scratch {scratch}")
    scratch.mkdir(parents=True, exist_ok=True)
    if scratch.resolve() != scratch or not scratch.is_dir():
        raise ValueError(f"policy scratch is not a real directory {scratch}")
    build_tmp = scratch / "build-tmp"
    if build_tmp.resolve() != build_tmp:
        raise ValueError(f"refusing symlinked compiler TMPDIR {build_tmp}")
    build_tmp.mkdir(exist_ok=True)
    os.environ["TMPDIR"] = str(build_tmp)
    source = SOURCE.read_text()
    function, calls = production_parts(source)
    work = Path(tempfile.mkdtemp(prefix="ventium-store-policy-shape.", dir=scratch))
    wrapper = ("module store_policy_shape(\n"
               " input logic [31:0] store_policy_addr, store_pair_policy_addr,\n"
               " input logic a20_enable,\n"
               " output logic [3:0] store_policy_update_mask, store_pair_policy_update_mask);\n"
               + function + calls + "endmodule\n")
    values = addresses()
    (work / "shape.sv").write_text(wrapper)
    (work / "driver.cpp").write_text(DRIVER.replace("@ADDRESSES@", ",".join(f"0x{x:08x}U" for x in values)))
    receipt = {"source": str(SOURCE),
               "source_sha256": hashlib.sha256(source.encode()).hexdigest(),
               "function_sha256": hashlib.sha256(function.encode()).hexdigest(),
               "calls_sha256": hashlib.sha256(calls.encode()).hexdigest(),
               "addresses": len(values), "checks": len(values) * 2 * 16,
               "scope": "actual extracted shim function and U/V calls; not cache composition"}
    (work / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"artifacts={work}", flush=True)
    with (work / "build.log").open("w") as log:
        command(["verilator", "--cc", "--exe", "--build", "--assert", "-j", "2",
                 "-Wno-fatal", "-Werror-IMPLICIT", "-Werror-PINMISSING", "-Werror-UNDRIVEN",
                 "-Werror-MULTIDRIVEN", "-Werror-LATCH", "-Werror-UNOPTFLAT",
                 "--top-module", "store_policy_shape", "-Mdir", str(work / "obj"),
                 "-o", "shape", str(work / "shape.sv"), str(work / "driver.cpp")], 240, log)
    command([str(work / "obj/shape")], 30)


if __name__ == "__main__":
    main()
