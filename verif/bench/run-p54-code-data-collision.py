#!/usr/bin/env python3
"""Bounded code/D-cache set-collision A/B, not gameplay or full verification."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "verif/diff"))
import tracefmt


def call(args, log, deadline):
    left = min(30, deadline - time.monotonic())
    if left <= 0:
        raise TimeoutError("nine-minute diagnostic budget exhausted")
    with log.open("w") as output:
        subprocess.run([str(x) for x in args], cwd=ROOT, check=True,
                       stdout=output, stderr=subprocess.STDOUT, timeout=left)


def symbols(path):
    return {fields[2]: int(fields[0], 16)
            for line in path.read_text().splitlines()
            if len(fields := line.split()) == 3}


def measure(binary, label, flat, sym, iterations, out, deadline):
    trace = out / f"{label}.vtrace"
    call([binary, "--cycle", "--l1-axi", "--image", flat,
          "--load", "0x08048000", "--entry", "0x08048000",
          "--out", trace, "--max-insn", iterations * 8 + 128,
          "--max-cycles", "2000000", "--quiesce", "1000"],
         out / f"{label}.log", deadline)
    records = tracefmt.read_trace(str(trace)).records
    pcs = [int(record["pc"], 0) for record in records]
    starts = [i for i, pc in enumerate(pcs) if pc == sym["loop_body"]]
    assert len(starts) == iterations, (label, "loop count", len(starts))
    assert sym["exit_syscall"] in pcs, (label, "no exit")
    assert all(right - left == 8 for left, right in zip(starts, starts[1:])), \
        (label, "nonuniform loop instruction count")
    begin, end = starts[100], starts[-1]
    clocks = int(records[end]["cyc"]) - int(records[begin]["cyc"])
    work = (iterations - 101) * 8
    assert clocks > 0
    return {"instructions": work, "clocks": clocks,
            "ipc": work / clocks,
            "cycles_per_iteration": clocks / (iterations - 101)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=1000)
    args = parser.parse_args()
    if not 102 <= args.iterations <= 10000:
        parser.error("iterations must be 102..10000")
    deadline = time.monotonic() + 540
    out = Path(tempfile.mkdtemp(prefix="p54-code-data-collision-"))
    print(f"Artifacts: {out}", flush=True)
    source = ROOT / "verif/bench/p54_code_data_collision.s"
    obj, elf, flat = [out / ("test." + ext) for ext in ("o", "elf", "flat")]
    call(["as", "--32", "--defsym", f"ITERATIONS={args.iterations}",
          source, "-o", obj], out / "as.log", deadline)
    call(["ld", "-m", "elf_i386", "-Ttext", "0x08048000", obj, "-o", elf],
         out / "ld.log", deadline)
    call(["nm", "-n", elf], out / "nm.log", deadline)
    call([sys.executable, ROOT / "verif/tests/elf2flat.py", elf,
          "--out", flat, "--base", "0x08048000"], out / "flat.log", deadline)
    sym = symbols(out / "nm.log")
    assert all(sym[name] % 4096 == 0
               for name in ("loop_body", "code_b", "code_c", "arena"))
    assert sym["code_b"] - sym["loop_body"] == 4096
    assert sym["code_c"] - sym["code_b"] == 4096
    results = {}
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = {label: pool.submit(measure, binary.resolve(), label, flat,
                                      sym, args.iterations, out, deadline)
                   for label, binary in (("control", args.control),
                                         ("candidate", args.candidate))}
        for label, future in futures.items():
            results[label] = future.result()
            print(f"{label}: {results[label]['cycles_per_iteration']:.3f} "
                  f"cycles/iteration; IPC {results[label]['ipc']:.6f}", flush=True)
    call([sys.executable, ROOT / "verif/diff/compare_stream.py",
          out / "control.vtrace", out / "candidate.vtrace"],
         out / "architectural-ab.log", deadline)
    (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print("P54-CODE-DATA-COLLISION-OK; architectural A/B equal; diagnostic only",
          flush=True)


if __name__ == "__main__":
    main()
