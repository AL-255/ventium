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
import compare as trace_compare

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
    "resident_hit_under_fill": (BASE, 31),
    "landed_word_forward": (BASE, 32),
    "regmem_prime_after_store": (BASE, 33),
    "regmem_prime_dep_reject": (BASE, 34),
    "fp_fistp_integer_overlap": (BASE, 35),
    "two_window_store_reuse": (BASE, 36),
    "dual_byte_load_distinct_bank": (BASE, 37),
    "dual_byte_load_same_bank": (BASE, 38),
    "dual_byte_load_line_edge": (BASE, 39),
    "dual_byte_load_high_regs": (BASE, 40),
    "dual_dword_load_window": (BASE, 41),
    "dual_dword_load_same_word": (BASE, 42),
    "dual_dword_load_line_edge": (BASE, 43),
    "dual_byte_cross_window": (BASE, 44),
    "dual_byte_cross_window_same_bank": (BASE, 45),
    "dual_byte_cross_window_steady": (BASE, 46),
    "dual_byte_cross_window_steady_same_bank": (BASE, 47),
    "ror_immediate_pipeline": (BASE, 48),
    "ror_immediate_count_edges": (BASE, 49),
    "fp_fistp_fractional_store": (BASE, 50),
    "fp_fist_fractional_nopop": (BASE, 51),
    "fp_fistp_empty_masked": (BASE, 52),
    "fp_fistp_split_page": (BASE, 53),
    "load_store_distinct_bank": (BASE, 54),
    "load_store_same_bank": (BASE, 55),
    "load_store_dependent_reject": (BASE, 56),
    "load_store_same_line": (BASE, 57),
    "load_store_spaced_distinct": (BASE, 58),
    "load_store_spaced_same_bank": (BASE, 59),
    "store_load_spaced_distinct": (BASE, 60),
    "store_load_spaced_same_bank": (BASE, 61),
    "store_load_spaced_alias": (BASE, 62),
    "xchg_eax_edi": (BASE, 63),
    "xchg_eax_ecx": (BASE, 64),
    "xchg_eax_esp": (BASE, 65),
    "adc_add_dual_read_distinct": (BASE, 66),
    "adc_add_dual_read_same_bank": (BASE, 67),
    "store_load_nospacer_distinct": (BASE, 68),
    "store_load_nospacer_same_bank": (BASE, 69),
    "store_load_nospacer_alias": (BASE, 70),
    "mem_zx8_dependent": (BASE, 71),
    "mem_zx16_dependent": (BASE, 72),
    "mem_sx8_dependent": (BASE, 73),
    "mem_sx16_dependent": (BASE, 74),
    "imul2_reg32": (BASE, 75),
    "imul2_mem32": (BASE, 76),
    "imul2_reg16": (BASE, 77),
    "imul2_mem16": (BASE, 78),
    "imul3_imm32": (BASE, 79),
    "imul3_imm16": (BASE, 80),
    "imul1_reg32": (BASE, 81),
    "imul1_reg16": (BASE, 82),
    "imul1_mem8": (BASE, 83),
    "fp_stack_overlap": (BASE, 84),
    "fp_pushesp_overlap": (BASE, 85),
    "fp_pop_same_overlap": (BASE, 86),
    "regmem_prime_alu_v": (BASE, 87),
    "regmem_prime_alu_after_store": (BASE, 88),
    "regmem_prime_alu_dep_reject": (BASE, 89),
    "regmem_prime_alu_sequential": (BASE, 90),
    "regmem_prime_alu_prev_addr_reject": (BASE, 91),
    "regmem_prime_alu_seq_dependent": (BASE, 92),
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
    # The byte/dword stress loops deliberately repeat eight U/V pairs. The
    # other directed loops keep the original short 4–6 instruction body.
    if case_id is not None and 37 <= case_id <= 43:
        assert count == 18, (name, count)
    else:
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
    x87_args = ["--x87"] if name.startswith("fp_") else []
    run([binary, "--cycle", *x87_args, "--l1-axi", "--image", flat,
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
    result = {"instructions": work, "clocks": clocks,
              "ipc": work / clocks,
              "cycles_per_iteration": clocks / (iterations - 101)}
    if "mixed_u" in sym and "mixed_v" in sym:
        result["mixed_pairs"] = sum(
            pc(records[index]) == sym["mixed_u"] and
            pc(records[index + 1]) == sym["mixed_v"] and
            clock(records[index]) == clock(records[index + 1])
            for index in range(len(records) - 1))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, help="candidate tb_ventium with VEN_L1_AXI")
    parser.add_argument("--control", type=Path, help="matched A/B control binary")
    parser.add_argument("--qemu", type=Path, help="pinned qemu-i386 for selected functional differential cases")
    parser.add_argument("--qemu-cases", nargs="+", choices=CASES,
                        help="cases to compare against full architectural QEMU traces")
    parser.add_argument("--cases", nargs="+", choices=CASES,
                        help="run only these named microbenchmarks (default: all)")
    parser.add_argument("--assemble-only", action="store_true")
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--jobs", type=int, default=min(32, os.cpu_count() or 1),
                        help="parallel simulator instances (default: up to 32)")
    parser.add_argument("--outdir", type=Path)
    args = parser.parse_args()
    if not args.assemble_only and args.binary is None:
        parser.error("--binary is required unless --assemble-only is used")
    if args.qemu_cases and (args.assemble_only or args.qemu is None):
        parser.error("--qemu-cases needs --qemu and an RTL --binary")
    selected = args.cases or list(CASES)
    if args.qemu_cases and not set(args.qemu_cases).issubset(selected):
        parser.error("--qemu-cases must be included in --cases")
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
    for name in selected:
        source, case_id = CASES[name]
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
                      f"cycles/iteration; IPC {row['ipc']:.6f}" +
                      (f"; mixed pairs {row['mixed_pairs']}" if
                       "mixed_pairs" in row else ""), flush=True)
        if {"adc_add_dual_read_distinct", "adc_add_dual_read_same_bank"} <= results.keys():
            distinct = results["adc_add_dual_read_distinct"]["candidate"]
            same_bank = results["adc_add_dual_read_same_bank"]["candidate"]
            assert distinct["cycles_per_iteration"] <= 3.0, \
                "independent ADC/ADD reads regressed behind separate EX clocks"
            assert same_bank["clocks"] >= distinct["clocks"], \
                "same-bank read unexpectedly beat the distinct-bank case"
        if {"store_load_nospacer_distinct", "store_load_nospacer_same_bank",
            "store_load_nospacer_alias"} <= results.keys():
            distinct = results["store_load_nospacer_distinct"]["candidate"]
            same_bank = results["store_load_nospacer_same_bank"]["candidate"]
            alias = results["store_load_nospacer_alias"]["candidate"]
            assert distinct["cycles_per_iteration"] <= 3.0, \
                "ordered non-alias store/load regressed"
            assert same_bank["clocks"] >= distinct["clocks"], \
                "same-bank store/load unexpectedly beat the distinct-bank case"
            assert alias["clocks"] >= distinct["clocks"], \
                "alias store/load unexpectedly beat the non-alias case"
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
            if "load_store_spaced_distinct" in results:
                row = results["load_store_spaced_distinct"]
                assert row["candidate"]["mixed_pairs"] >= args.iterations - 2, \
                    "spaced mixed pair did not issue on warmed iterations"
                # Another A/B experiment may use two binaries that already
                # enable this mixed-pair feature. Require a speedup only when
                # candidate actually adds pairs relative to its control.
                if row["candidate"]["mixed_pairs"] > row["control"]["mixed_pairs"]:
                    assert row["candidate"]["clocks"] < row["control"]["clocks"], \
                        "spaced mixed pair did not save fixed-work clocks"
            for accelerated in ("regmem_prime_alu_v",
                                "regmem_prime_alu_after_store",
                                "regmem_prime_alu_seq_dependent"):
                if accelerated in results:
                    row = results[accelerated]
                    if row["candidate"]["mixed_pairs"] > row["control"]["mixed_pairs"]:
                        assert row["candidate"]["mixed_pairs"] >= args.iterations - 2, \
                            (accelerated, "insufficient V ALU pairing")
                        assert row["candidate"]["clocks"] < row["control"]["clocks"], \
                            (accelerated, "pairing did not save fixed-work clocks")
            for rejected in ("regmem_prime_alu_dep_reject",
                             "regmem_prime_alu_prev_addr_reject"):
                if rejected in results:
                    assert results[rejected]["candidate"]["mixed_pairs"] == 0, \
                        (rejected, "dependent V address was speculatively paired")
            for rejected in ("load_store_same_bank", "load_store_dependent_reject",
                             "load_store_spaced_same_bank"):
                if rejected in results:
                    assert results[rejected]["candidate"]["mixed_pairs"] == 0, rejected
        for index, name in enumerate(args.qemu_cases or []):
            flat, sym, per_loop = prepared[name]
            directory = out / name
            golden = directory / "qemu.vtrace"
            functional = directory / "candidate_func.vtrace"
            x87_args = ["--x87"] if name.startswith("fp_") else []
            run([sys.executable, ROOT / "verif/qemu-trace/gen_trace.py",
                 "--qemu", args.qemu.resolve(), "--elf", directory / "test.elf",
                 "--out", golden, "--max-insn", args.iterations * per_loop + 128,
                 "--port", 28351 + index, *x87_args], deadline, directory / "qemu.log")
            golden_records = tracefmt.read_trace(str(golden)).records
            assert golden_records, (name, "empty QEMU trace")
            init_esp = golden_records[0]["esp"]
            run([args.binary.resolve(), *x87_args, "--l1-axi", "--image", flat,
                 "--load", "0x08048000", "--entry", "0x08048000",
                 "--init-esp", init_esp, "--out", functional,
                 "--max-insn", args.iterations * per_loop + 128,
                 "--max-cycles", "200000", "--quiesce", "1000"],
                deadline, directory / "candidate_func.log")
            run([sys.executable, ROOT / "verif/diff/compare_stream.py",
                 golden, functional], deadline, directory / "qemu_diff.log")
            results[name]["qemu_architectural_equal"] = True
            # The new pairing paths are active in cycle mode, not in the
            # functional-mode run above. Check the actual cycle-mode post-state
            # at each completed issue group against QEMU. The U callback in a
            # same-clock pair sees both committed writes, so its intermediate
            # snapshot is not a standalone architectural comparison point.
            cycle_state = directory / "candidate_cycle_func.vtrace"
            run([args.binary.resolve(), "--cycle-func", *x87_args, "--l1-axi", "--image", flat,
                 "--load", "0x08048000", "--entry", "0x08048000",
                 "--init-esp", init_esp, "--out", cycle_state,
                 "--max-insn", args.iterations * per_loop + 128,
                 "--max-cycles", "200000", "--quiesce", "1000"],
                deadline, directory / "candidate_cycle_func.log")
            cycles = tracefmt.read_trace(str(directory / "candidate.vtrace")).records
            states = tracefmt.read_trace(str(cycle_state)).records
            assert len(cycles) == len(states) == len(golden_records) + 1, \
                (name, "cycle/group trace length")
            assert all(int(row["pc"], 0) == sym["exit_syscall"]
                       for row in (cycles[-1], states[-1])), name
            fields = ("eax", "ebx", "ecx", "edx", "esi", "edi", "esp", "ebp",
                      "cs", "ss", "ds", "es", "fs", "gs")
            if x87_args:
                fields += tuple(f"st{index}" for index in range(8)) + \
                          ("fctrl", "fstat", "ftag")
            checked = 0
            for i, expected in enumerate(golden_records):
                assert int(cycles[i]["pc"], 0) == \
                       int(states[i]["pc"], 0) == int(expected["pc"], 0), \
                    (name, i, "pc")
                if i + 1 < len(golden_records) and \
                   cycles[i]["cyc"] == cycles[i + 1]["cyc"]:
                    continue
                for key in fields:
                    assert states[i][key] == expected[key], \
                        (name, i, key, states[i][key], expected[key])
                flags_match, mask = trace_compare._eflags_equal(
                    expected["eflags"], states[i]["eflags"],
                    tracefmt.EFLAGS_DEFAULT_MASK,
                    trace_compare._mnemonic_from_bytes(expected.get("bytes")))
                assert flags_match, \
                    (name, i, "eflags", states[i]["eflags"], expected["eflags"], mask)
                checked += 1
            results[name]["qemu_cycle_group_states_equal"] = checked
            print(f"{name}: {checked}/{len(golden_records)} cycle-mode group states "
                  "match pinned QEMU", flush=True)
        (out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print("Diagnostic only: no full verification or gameplay claim.", flush=True)
    print("P54-IPC-MICRO-OK", flush=True)


if __name__ == "__main__":
    main()
