#!/usr/bin/env python3
"""Bounded fixed-work P54 IPC diagnostics; never builds RTL or runs full gates."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "verif/diff"))
import tracefmt

BASE = ROOT / "verif/bench/p54_ipc_cases.s"
PRIME = ROOT / "verif/issue_uv/t_reg_load_prime_ipc.s"
CASES = {
    "reg_load_prime": (PRIME, None),
    "dual_load_distinct_bank": (BASE, 1),
    "dual_load_same_bank": (BASE, 2),
    "dual_store_distinct_bank": (BASE, 3),
    "dual_store_same_bank": (BASE, 4),
    "resident_memory_alu": (BASE, 5),
    "register_alu_control": (BASE, 6),
    "fp_integer_overlap": (BASE, 7),
    "integer_only_control": (BASE, 8),
    "frontend_aligned": (BASE, 9),
    "frontend_line_straddle": (BASE, 10),
    "resident_same_line_loads": (BASE, 11),
    "resident_two_line_loads": (BASE, 12),
    "register_u_memory_v": (BASE, 13),
    "memory_u_register_v": (BASE, 14),
    "memory_alu_integer_v": (BASE, 15),
    "resident_memory_or": (BASE, 16),
    "resident_memory_adc": (BASE, 17),
    "resident_memory_sbb": (BASE, 18),
    "resident_memory_and": (BASE, 19),
    "resident_memory_sub": (BASE, 20),
    "resident_memory_xor": (BASE, 21),
    "branch_target_load": (BASE, 22),
    "v_branch_target_load": (BASE, 23),
    "v_branch_fallthrough_load": (BASE, 24),
    "branch_fallthrough_load": (BASE, 25),
    "branch_fallthrough_mispredict": (BASE, 26),
    "v_branch_fallthrough_mispredict": (BASE, 27),
    "dual_load_after_store": (BASE, 28),
    "dual_load_after_store_same_bank": (BASE, 29),
    "resident_xline_return": (BASE, 30),
}


def run(argv, deadline, log):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("the nine-minute microbenchmark budget expired")
    with log.open("w") as stream:
        subprocess.run([str(x) for x in argv], cwd=ROOT, stdout=stream,
                       stderr=subprocess.STDOUT, check=True,
                       timeout=min(30, remaining))


def symbols(path):
    return {fields[2]: int(fields[0], 16)
            for line in path.read_text().splitlines()
            if len(fields := line.split()) == 3}


def body_instruction_count(disasm, start, end):
    pcs = [int(match.group(1), 16)
           for line in disasm.read_text().splitlines()
           if (match := re.match(r"^\s*([0-9a-f]+):\s+[0-9a-f]{2}\s", line))]
    return sum(start <= pc < end for pc in pcs)


def assemble(name, source, case_id, iterations, out, deadline):
    directory = out / name
    directory.mkdir()
    obj, elf, flat = [directory / ("test." + ext) for ext in ("o", "elf", "flat")]
    defines = ["--defsym", f"ITERATIONS={iterations}"]
    if case_id is not None:
        defines += ["--defsym", f"CASE={case_id}"]
    run(["as", "--32", *defines, source, "-o", obj], deadline, directory / "as.log")
    run(["ld", "-m", "elf_i386", "-Ttext", "0x08048000", obj, "-o", elf],
        deadline, directory / "ld.log")
    run(["nm", "-n", elf], deadline, directory / "nm.log")
    run(["objdump", "-d", elf], deadline, directory / "disasm.log")
    run([sys.executable, ROOT / "verif/tests/elf2flat.py", elf, "--out", flat,
         "--base", "0x08048000"], deadline, directory / "flat.log")
    sym = symbols(directory / "nm.log")
    assert all(key in sym for key in ("loop_body", "loop_end", "exit_syscall")), name
    count = body_instruction_count(directory / "disasm.log", sym["loop_body"], sym["loop_end"])
    assert 4 <= count <= 6, (name, count)
    if name == "frontend_aligned":
        assert sym["loop_body"] % 32 == 0
    if name == "frontend_line_straddle":
        assert sym["loop_body"] % 32 == 31
    if name == "reg_load_prime":
        assert count == 6
    return flat, sym, count


def measure(name, label, binary, flat, sym, per_loop, iterations, out, deadline):
    directory = out / name
    trace_path = directory / f"{label}.vtrace"
    run([binary, "--cycle", "--l1-axi", "--image", flat,
         "--load", "0x08048000", "--entry", "0x08048000",
         "--out", trace_path, "--max-insn", iterations * per_loop + 128,
         "--max-cycles", "200000", "--quiesce", "1000"],
        deadline, directory / f"{label}.log")
    records = tracefmt.read_trace(str(trace_path)).records
    pc = lambda record: int(record["pc"], 0)
    clock = lambda record: int(record["cyc"])
    starts = [i for i, record in enumerate(records) if pc(record) == sym["loop_body"]]
    assert len(starts) == iterations, (name, label, "loop count", len(starts))
    assert any(pc(record) == sym["exit_syscall"] for record in records), \
        (name, label, "guest did not reach exit")
    for left, right in zip(starts, starts[1:]):
        body = sum(sym["loop_body"] <= pc(record) < sym["loop_end"]
                   for record in records[left:right])
        assert body == per_loop, (name, label, "incomplete loop", body)
    begin, end = starts[100], starts[-1]
    clocks = clock(records[end]) - clock(records[begin])
    work = (iterations - 101) * per_loop
    assert clocks > 0
    return {"instructions": work, "clocks": clocks,
            "ipc": work / clocks, "cycles_per_iteration": clocks / (iterations - 101)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, help="candidate tb_ventium with VEN_L1_AXI")
    parser.add_argument("--control", type=Path, help="matched A/B control binary")
    parser.add_argument("--assemble-only", action="store_true")
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--jobs", type=int, default=min(32, os.cpu_count() or 1),
                        help="parallel simulator instances (default: up to 32)")
    parser.add_argument("--outdir", type=Path)
    args = parser.parse_args()
    if not args.assemble_only and args.binary is None:
        parser.error("--binary is required unless --assemble-only is used")
    if not 102 <= args.iterations <= 10000:
        parser.error("iterations must be between 102 and 10000")
    if not 1 <= args.jobs <= 32:
        parser.error("jobs must be between 1 and 32")
    # Each subprocess also has a 30-second cap. The whole suite is bounded
    # below the user's 10-minute ceiling, including assembly and trace parsing.
    deadline = time.monotonic() + 540
    out = args.outdir.resolve() if args.outdir else Path(tempfile.mkdtemp(prefix="p54-ipc-micro-"))
    out.mkdir(parents=True, exist_ok=True)
    print(f"Artifacts: {out}", flush=True)
    results = {}
    prepared = {}
    for name, (source, case_id) in CASES.items():
        flat, sym, per_loop = assemble(name, source, case_id, args.iterations, out, deadline)
        prepared[name] = (flat, sym, per_loop)
        if args.assemble_only:
            print(f"{name}: assembled, {per_loop} instructions/iteration", flush=True)
    if not args.assemble_only:
        tasks = {}
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for name, (flat, sym, per_loop) in prepared.items():
                binaries = {"candidate": args.binary.resolve()}
                if args.control:
                    binaries["control"] = args.control.resolve()
                for label, binary in binaries.items():
                    try:
                        future = pool.submit(measure, name, label, binary, flat, sym,
                                             per_loop, args.iterations, out, deadline)
                    except RuntimeError:
                        # Thread creation can fail before the first completed
                        # result when the bounded scope's task cap is too low.
                        # Emit the exact cgroup pressure rather than guessing
                        # whether this was memory, host, or scope PID pressure.
                        cg = next((line.split(':', 2)[2] for line in
                                   Path('/proc/self/cgroup').read_text().splitlines()
                                   if line.startswith('0::')), '')
                        for metric in ('pids.current', 'pids.max', 'memory.current',
                                       'memory.max', 'memory.events'):
                            path = Path('/sys/fs/cgroup') / cg.lstrip('/') / metric
                            if path.exists():
                                print(f'build scope {metric}: {path.read_text().strip()}',
                                      file=sys.stderr, flush=True)
                        procs = Path('/sys/fs/cgroup') / cg.lstrip('/') / 'cgroup.procs'
                        if procs.exists():
                            counts = []
                            for pid in procs.read_text().splitlines():
                                status = Path('/proc') / pid / 'status'
                                if not status.exists():
                                    continue
                                fields = dict(line.split(':', 1) for line in
                                              status.read_text().splitlines() if ':' in line)
                                counts.append((int(fields.get('Threads', '0')), pid,
                                               fields.get('Name', '').strip()))
                            print(f'build scope process/thread owners: {sorted(counts, reverse=True)[:12]}',
                                  file=sys.stderr, flush=True)
                        raise
                    tasks[future] = (name, label)
            for future in as_completed(tasks):
                name, label = tasks[future]
                results.setdefault(name, {})[label] = future.result()
                row = results[name][label]
                print(f"{name}/{label}: {row['cycles_per_iteration']:.3f} "
                      f"cycles/iteration; IPC {row['ipc']:.6f}", flush=True)
        if args.control:
            # Performance is meaningful only for identical architectural work.
            # This short A/B check is not a substitute for the QEMU differential
            # gate, but catches incorrect candidate state in every directed case.
            for name in prepared:
                directory = out / name
                run([sys.executable, ROOT / "verif/diff/compare_stream.py",
                     directory / "control.vtrace", directory / "candidate.vtrace"],
                    deadline, directory / "architectural-ab.log")
                results[name]["architectural_ab_equal"] = True
            print("All directed candidate/control architectural traces match.", flush=True)
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print("Diagnostic only: no full verification or gameplay claim.", flush=True)
    print("P54-IPC-MICRO-OK", flush=True)


if __name__ == "__main__":
    main()
