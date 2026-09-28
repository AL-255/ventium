#!/usr/bin/env python3
"""Bounded paired-store executable-coherence microtest, not a full gate."""
import argparse
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "verif/diff"))
import compare
import tracefmt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tb", required=True, type=Path)
    parser.add_argument("--outdir", required=True, type=Path)
    args = parser.parse_args()
    out = args.outdir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + 240

    def run(argv, label):
        with (out / f"{label}.log").open("w") as log:
            subprocess.run([str(part) for part in argv], cwd=ROOT, stdout=log,
                           stderr=subprocess.STDOUT, check=True,
                           timeout=min(45, deadline - time.monotonic()))

    obj, elf, flat = [out / f"test.{ext}" for ext in ("o", "elf", "flat")]
    source = ROOT / "verif/issue_uv/t_dual_store_smc.s"
    run(["as", "--32", source, "-o", obj], "as")
    run(["ld", "-m", "elf_i386", "-T", ROOT / "verif/rep_sfetch/t_rep_smc.ld",
         "-z", "max-page-size=0x1000", obj, "-o", elf], "ld")
    run(["nm", "-n", elf], "nm")
    symbol = {p[2]: int(p[0], 16) for line in (out / "nm.log").read_text().splitlines()
              if len(p := line.split()) == 3}
    assert (symbol["patch_u"] + 1) % 32 == 4
    assert (symbol["patch_v"] + 1) % 32 == 8
    assert (symbol["patch_u"] >> 5) != (symbol["patch_v"] >> 5)
    run([sys.executable, ROOT / "verif/tests/elf2flat.py", elf, "--out", flat,
         "--base", "0x08048000"], "flat")
    golden = out / "qemu.vtrace"
    run([sys.executable, ROOT / "verif/qemu-trace/gen_trace.py", "--qemu",
         ROOT / "ventium-refs/07-p5-emulation-harness/build/qemu/build/qemu-i386",
         "--elf", elf, "--out", golden, "--max-insn", "2000", "--port", "41921"],
        "qemu")
    assert "guest exited, code=0" in (out / "qemu.log").read_text()
    gold = tracefmt.read_trace(str(golden))
    traces = {}
    for mode in ("cycle", "cycle-func"):
        path = out / f"{mode}.vtrace"
        run([args.tb.resolve(), f"--{mode}", "--l1-axi", "--image", flat,
             "--load", "0x08048000", "--entry", "0x08048000",
             "--init-esp", gold.records[0]["esp"], "--out", path,
             "--max-insn", "2000", "--max-cycles", "100000", "--quiesce", "1000"],
            mode)
        traces[mode] = tracefmt.read_trace(str(path))
    cycle = traces["cycle"].records
    state = traces["cycle-func"].records
    assert len(cycle) == len(state) == len(gold.records) + 1
    assert int(cycle[-1]["pc"], 0) == int(state[-1]["pc"], 0) == symbol["exit_syscall"]
    cycle.pop()
    state.pop()
    assert [r["pc"] for r in gold.records] == [r["pc"] for r in cycle] == [r["pc"] for r in state]
    first = [i for i, r in enumerate(cycle) if int(r["pc"], 0) == symbol["first_store"]]
    second = [i for i, r in enumerate(cycle) if int(r["pc"], 0) == symbol["second_store"]]
    assert len(first) == len(second) == 64
    pairs = sum(cycle[i]["cyc"] == cycle[j]["cyc"] for i, j in zip(first, second))
    assert pairs > 0, "V executable store never actually paired"
    ends = [i for i in range(len(cycle)) if i + 1 == len(cycle) or
            cycle[i]["cyc"] != cycle[i + 1]["cyc"]]
    with (out / "compare.log").open("w") as log:
        assert compare.compare_func(
            tracefmt.Trace(gold.hdr, [gold.records[i] for i in ends]),
            tracefmt.Trace(traces["cycle-func"].hdr, [state[i] for i in ends]),
            False, 0xffffffff, False, 20, log) == 0
    print(f"DUAL-STORE-SMC-OK: {pairs}/64 V stores paired; "
          f"{len(ends)} QEMU-equivalent architectural groups; artifacts {out}")


if __name__ == "__main__":
    main()
