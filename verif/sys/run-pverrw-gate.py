#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Bounded, no-rebuild VERR/VERW qualification on an explicitly frozen TB.

Cases1..8 require an independent QEMU debug-exit133 AND a complete unmodified
architectural differential. Cases9/10 are Intel-spec-only (pinned QEMU omits
LOCK/per-access-segment rejection); case10 requires the actual colocated
compile record to contain VEN_SEG_ENFORCE. All cases require RTL133,
exact ordinary fault events, terminal self-check witnesses, and closed inputs.
This is a directed ISA gate, not Windows95/Quake/standard-suite acceptance.

Example (all hashes come from a reviewed frozen build receipt):
  python3 -B verif/sys/run-pverrw-gate.py --tb /absolute/obj_dir_X/tb_ventium \
    --tb-sha256 SHA --compile-sha256 SHA --out /absolute/obj_dir_X/pverrw-new \
    --cases first7 --jobs 4 --port-base 41470

Outputs are fresh private leaves under existing owned, nonsymlink rootfs
parents. No image assembly, model build, live disk, or snapshot is used.
"""
from __future__ import annotations

import argparse
from contextlib import ExitStack
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "verif/sys/tests/pverrw"
QEMU = REPO / "ventium-refs/07-p5-emulation-harness/build/qemu/build-sys/qemu-system-i386"
QEMU_SHA = "b42b70e5109638df22ff736c18b93c40881faa30dc5f52f4d119dda3be3467fd"
sys.path.insert(0, str(REPO / "verif/diff"))
import tracefmt
sys.path.insert(0, str(REPO / "verif/sys"))
import check_faultlog

COUNTS = {1: (50, 0), 2: (22, 0), 3: (2, 2), 4: (4, 2), 5: (0, 4),
          6: (0, 3), 7: (6, 0), 8: (8, 8), 9: (0, 4), 10: (6, 6)}
FAULT_NAMES = {3: (14, ["operand_fault1", "operand_fault2"]),
               4: (14, ["descriptor_fault1", "descriptor_fault2"]),
               5: (6, ["real_r", "real_w66", "real_mem_r", "real_mem_w67"]),
               6: (6, ["vm_r", "vm_mem_w", "vm_r66"]),
               9: (6, ["lock_verr_reg", "lock_verw_reg66", "lock_verr_mem", "lock_verw_mem66"])}
TRAP_NAMES = ["tf_verr_valid", "tf_verr_null", "tf_verw_valid", "tf_verw_ro",
              "tf_lar_valid", "tf_lar_null", "tf_lsl_valid", "tf_lsl_null"]
LOG_LIMIT = 16 * 1024 * 1024
MAX_INSN = 12000
FATAL = re.compile(r"%Error|Assertion failed|FATAL|CPU HUNG|UNIMPLEMENTED")


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def pin(path, expected):
    if not re.fullmatch(r"[0-9a-f]{64}", expected) or digest(path) != expected:
        raise ValueError(f"frozen input hash mismatch: {path}")


def compile_profile(text):
    lines = [line[3:-1] for line in text.splitlines()
             if line.startswith('C "') and line.endswith('"')]
    if len(lines) != 1:
        raise ValueError("expected one complete Verilator compile command")
    argv = shlex.split(lines[0])
    if argv.count("-Mdir") != 1 or argv.count("--top-module") != 1:
        raise ValueError("compile record lacks unique -Mdir/top-module")
    if argv[argv.index("--top-module") + 1] != "ventium_top":
        raise ValueError("wrong compiled testbench top")
    defines = set()
    for arg in argv:
        if arg.startswith("+define+"):
            defines.update(item.split("=", 1)[0] for item in arg[8:].split("+"))
    return argv, defines


def validate_build(tb, tb_sha, compile_record, compile_sha, cases,
                   compile_cwd=REPO / "verif/tb"):
    tb = Path(tb)
    compile_record = Path(compile_record)
    if not tb.is_file() or not os.access(tb, os.X_OK):
        raise ValueError("missing frozen executable TB")
    pin(tb, tb_sha)
    pin(compile_record, compile_sha)
    if compile_record.resolve().parent != tb.resolve().parent:
        raise ValueError("compile record is not colocated with frozen TB")
    argv, defines = compile_profile(compile_record.read_text())
    mdir = Path(argv[argv.index("-Mdir") + 1])
    if not mdir.is_absolute():
        mdir = Path(compile_cwd) / mdir
    if mdir.resolve() != tb.resolve().parent:
        raise ValueError("actual compiled -Mdir is not frozen TB directory")
    if 10 in cases and "VEN_SEG_ENFORCE" not in defines:
        raise ValueError("case10 requires actual compiled VEN_SEG_ENFORCE")
    return sorted(defines)


def parse_cases(value):
    if value == "first7":
        return list(range(1, 8))
    if value == "all":
        return list(range(1, 11))
    if not re.fullmatch(r"(?:10|[1-9])(?:,(?:10|[1-9]))*", value):
        raise ValueError("--cases must be first7, all, or comma-separated1..10")
    result = [int(item) for item in value.split(",")]
    if len(result) != len(set(result)):
        raise ValueError("duplicate selected case")
    return result


def validate_variant(variant, sym):
    case = variant["case"]
    if case not in COUNTS or (variant["queries"], variant["faults"]) != COUNTS[case]:
        raise ValueError("unreviewed fixture counts")
    if (sym["query_expected"], sym["fault_expected"]) != COUNTS[case]:
        raise ValueError("ELF count constants disagree with reviewed variant")
    faults = variant.get("expected_faults", [])
    if case in FAULT_NAMES:
        vec, names = FAULT_NAMES[case]
        wanted = [(vec, 0, name) for name in names]
    elif case == 10:
        wanted = [(13, 0, name) for name in ("gp_null_verr", "gp_null_verw66",
                  "gp_limit_verr", "gp_limit_verw66")]
        wanted += [(12, 0, name) for name in ("ss_limit_verr", "ss_limit_verw66")]
        if (variant.get("oracle") != "intel-spec"
                or variant.get("required_defines") != ["VEN_SEG_ENFORCE"]):
            raise ValueError("case10 oracle/profile contract changed")
    else:
        wanted = []
    if [(f["vector"], f["error"], f["symbol"]) for f in faults] != wanted:
        raise ValueError("fault contract missing, weakened, or reordered")
    if case == 9 and variant.get("oracle") != "intel-spec":
        raise ValueError("case9 must explicitly retain the LOCK oracle limitation")
    for fault in faults:
        if fault.get("pc_mode", "flat") != {5: "real16", 6: "v86"}.get(case, "flat"):
            raise ValueError("wrong fault PC ownership")
        if case == 6 and fault.get("base_symbol") != "v86_start":
            raise ValueError("missing V86 relocation owner")
        sym[fault["symbol"]]
    traps = variant.get("expected_traps", [])
    if case == 8:
        if (variant.get("trap_handler") != "db_handler"
                or [(t["vector"], t["symbol"], t["end_symbol"]) for t in traps]
                != [(1, name, name + "_end") for name in TRAP_NAMES]):
            raise ValueError("missing or reordered TF trap contract")
        sym["db_handler"]
        for item in traps:
            if sym[item["end_symbol"]] != sym[item["symbol"]] + 3:
                raise ValueError("unexpected TF query instruction extent")
    elif traps:
        raise ValueError("unexpected trap contract")


def expected_faults(variant, sym):
    result = []
    for item in variant.get("expected_faults", []):
        pc = sym[item["symbol"]]
        if item.get("pc_mode") == "real16":
            pc -= 0xF0000
        elif item.get("pc_mode") == "v86":
            pc -= sym[item["base_symbol"]]
        if not 0 <= pc < 2**32:
            raise ValueError("invalid fault PC")
        result.append((item["vector"], item["error"], pc))
    return result


def read_complete_trace(path):
    path = Path(path)
    if not 0 < path.stat().st_size <= LOG_LIMIT:
        raise ValueError("missing or oversized trace")
    with path.open("rb") as src:
        src.seek(-1, os.SEEK_END)
        if src.read(1) != b"\n":
            raise ValueError("truncated trace: missing final newline")
    return tracefmt.read_trace(str(path))


def validate_trace(trace, producer):
    if (trace.hdr.get("vtrace") != 1 or trace.hdr.get("producer") != producer
            or trace.mode != "func" or trace.hdr.get("sys") is not True or trace.x87):
        raise ValueError("wrong functional system trace header")
    rows = trace.records
    if not rows or len(rows) >= MAX_INSN:
        raise ValueError("empty or instruction-cap-exhausted trace")
    keys = tracefmt.func_compare_keys(False, True)
    for n, row in enumerate(rows):
        if type(row.get("n")) is not int or row["n"] != n or not all(k in row for k in keys):
            raise ValueError("incomplete/noncontiguous architectural trace")
        for key in keys:
            value = tracefmt.parse_hex(row[key])
            if not 0 <= value < (1 << tracefmt._WIDTH[key]):
                raise ValueError(f"out-of-range architectural {key}")
    return rows


def grade_terminal(trace, variant, sym, image, producer):
    rows = validate_trace(trace, producer)
    validate_variant(variant, sym)
    case = variant["case"]
    name, width = ("real_do_out", 3) if case == 5 else ("do_out", 4)
    offset = sym[name] - 0xF0000
    mov = b"\xba\xf4\x00" if case == 5 else b"\x66\xba\xf4\x00"
    if len(image) != 65536 or image[offset - width:offset + 1] != mov + b"\xee":
        raise ValueError("ELF/BIOS debug-exit instruction mismatch")
    pc = sym[name] - (0xF0000 if case == 5 else 0)
    last = rows[-1]
    if tracefmt.parse_hex(last["pc"]) not in {pc - width, pc}:
        raise ValueError("final record is not actual debug-exit path")
    witnesses = dict(eax=0x42, ebx=case, ecx=variant["queries"],
                     ebp=variant["faults"], edi=0, esi=0x600D0F00)
    for key, value in witnesses.items():
        if tracefmt.parse_hex(last[key]) != value:
            raise ValueError(f"wrong terminal {key}")
    if tracefmt.parse_hex(last["edx"]) & 0xFFFF != 0xF4:
        raise ValueError("wrong debug-exit port DX")
    if case == 8:
        pcs = [tracefmt.parse_hex(row["pc"]) for row in rows]
        handlers = [n for n, pc in enumerate(pcs) if pc == sym["db_handler"]]
        if len(handlers) != 8:
            raise ValueError("missing/additional TF handler entries")
        # The legacy DPI delivers a marker at the query's source PC, possibly
        # alongside its normal query record. Do not drop/align either stream
        # here: the full canonical differential below grades all of them.
        lower = 0
        for index, (item, handler) in enumerate(zip(variant["expected_traps"], handlers)):
            if not any(pc == sym[item["symbol"]] for pc in pcs[lower:handler]):
                raise ValueError("missing/reordered TF source before handler")
            if not any(pc == sym[item["end_symbol"]]
                       for pc in pcs[handler + 1:handlers[index + 1]
                                     if index + 1 < len(handlers) else len(pcs)]):
                raise ValueError("missing TF resume after handler")
            lower = handler + 1
    return len(rows)


def grade_native(trace, log, sym, variant, image, return_code):
    if return_code != 133:
        raise ValueError("actual RTL wait status is not debug-exit133")
    count = grade_terminal(trace, variant, sym, image, "rtl")
    if not log.endswith("\n") or FATAL.search(log):
        raise ValueError("truncated or fatal native log")
    stops = [line for line in log.splitlines() if line.startswith("tb: stop:")]
    if len(stops) != 1:
        raise ValueError("not one native debug-exit stop")
    stop = re.fullmatch(r"tb: stop: WIN95 co-sim isa-debug-exit \(out 0xf4\) "
                        r"after (\d+) retired in (\d+) clocks", stops[0])
    footers = re.findall(r"^tb: retired (\d+) instructions in (\d+) clocks "
                         r"\(bus: \d+ reads, \d+ writes\)$", log, re.MULTILINE)
    if (not stop or int(stop[1]) != count or int(stop[2]) <= 0
            or footers != [(stop[1], stop[2])]):
        raise ValueError("missing/mismatching complete native closure")
    cosim = [line for line in log.splitlines() if line.startswith("tb: M7.3b")]
    if cosim != ["tb: M7.3b win95 co-sim: 0 IN reads serviced "
                 "(0 dev_in available, cursor at 0), 1 OUT writes consumed, "
                 "0 port/size desync(s), isa-debug-exit reached"]:
        raise ValueError("missing/duplicate/desynchronized normal I/O closure")
    faults = []
    for line in log.splitlines():
        if "[FAULT]" not in line:
            continue
        fault = check_faultlog.FAULT.fullmatch(line)
        if not fault:
            raise ValueError("malformed native fault event")
        pc = re.search(r" pc=([0-9a-fA-F]{8}) ", line)[1]
        faults.append((int(fault[1]), int(fault[2], 16), int(pc, 16)))
    if faults != expected_faults(variant, sym):
        raise ValueError(f"wrong ordered native fault events: {faults!r}")
    return dict(result="PASS", case=variant["case"], records=count,
                clocks=int(stop[2]), actual_return_code=return_code,
                ordinary_faults=[list(f) for f in faults],
                tf_traps=len(variant.get("expected_traps", [])),
                record_note="Legacy DPI counts include delivery markers; no records removed.")


def grade_golden(trace, log, sym, variant, image, return_code, free_return_code):
    if return_code != 0 or free_return_code != 133:
        raise ValueError("golden requires generator0 AND actual free QEMU133")
    count = grade_terminal(trace, variant, sym, image, "qemu-gdbstub")
    if not log.endswith("\n") or FATAL.search(log):
        raise ValueError("truncated/fatal golden log")
    footers = re.findall(r"^\[gen_trace\] wrote (\d+) records to [^\r\n]+ "
                         r"\(guest exited, code=0\)$", log, re.MULTILINE)
    if footers != [str(count)]:
        raise ValueError("missing/mismatching terminal golden footer")
    return count


def symbols(elf):
    result = subprocess.run(["nm", "-n", str(elf)], check=True, text=True,
                            capture_output=True, timeout=5)
    return {p[2]: int(p[0], 16) for line in result.stdout.splitlines()
            if len(p := line.split()) == 3}


def safe_output(path):
    path = Path(path)
    if (not path.is_absolute() or str(path) != str(path.resolve())
            or path.exists() or path.is_symlink() or not path.parent.is_dir()
            or path.parent.stat().st_uid != os.getuid()):
        raise ValueError("--out must be a fresh absolute nonsymlink owned leaf")
    if os.statvfs(path.parent).f_bavail * os.statvfs(path.parent).f_frsize < 256 * 1024**2:
        raise ValueError("less than256MiB available on output filesystem")
    return path


def lock_fds():
    result = []
    for entry in Path("/proc/self/fd").iterdir():
        try:
            if entry.resolve() == Path("/tmp/ventium-heavy-build.lock"):
                result.append(int(entry.name))
        except OSError:
            continue
    return tuple(result)


def ensure_guard():
    guard = REPO / "tools/build_scope.sh"
    active = subprocess.run([str(guard), "--is-active"], pass_fds=lock_fds(),
                            timeout=5).returncode == 0
    if active:
        return
    env = dict(os.environ)
    env.pop("VENTIUM_BUILD_SCOPE_UNIT", None)
    env.pop("VENTIUM_BUILD_SCOPE_PROFILE", None)
    # No compiler runs, but the guard itself otherwise defaults to the full
    # external-volume tmp symlink. Use the existing validated rootfs parent.
    env["TMPDIR"] = str(Path(parse_arguments().out).parent)
    os.execve(str(guard), [str(guard), "--", "timeout", "--kill-after=5s", "540s",
                          sys.executable, "-B", str(Path(__file__).resolve()),
                          *sys.argv[1:]], env)


def group_members(group):
    result = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry / "stat").read_text()
            tail = stat[stat.rfind(")") + 2:].split()
            if int(tail[2]) == group and tail[0] != "Z":
                result.append(int(entry.name))
        except (OSError, ValueError, IndexError):
            continue
    return result


def clean_group(group):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if not group_members(group):
            return
        try:
            os.killpg(group, sig)
        except ProcessLookupError:
            return
        end = time.monotonic() + 1
        while group_members(group) and time.monotonic() < end:
            time.sleep(0.02)
    if group_members(group):
        raise ValueError(f"owned process group{group} did not close")


def command(argv, log, limit, deadline, expected, stderr=None):
    allowance = min(limit, deadline - time.monotonic())
    if allowance <= 0:
        raise ValueError("global540s deadline exhausted")
    env = {key: val for key, val in os.environ.items()
           if not key.startswith(("VEN_", "AO486_", "VTM_"))}
    # A file-size limit fails closed on runaway native/golden diagnostics.
    wrapped = ["prlimit", f"--fsize={LOG_LIMIT}", "--core=0", "--", *map(str, argv)]
    start = time.monotonic()
    with ExitStack() as files:
        output = files.enter_context(Path(log).open("xb"))
        error_output = files.enter_context(Path(stderr).open("xb")) if stderr else subprocess.STDOUT
        process = subprocess.Popen(wrapped, stdout=output, stderr=error_output,
                                   start_new_session=True, env=env, pass_fds=lock_fds())
        try:
            code = process.wait(timeout=allowance)
        except BaseException:
            clean_group(process.pid)
            process.wait(timeout=2)
            raise
        leftover = group_members(process.pid)
        clean_group(process.pid)
    receipt = dict(argv=list(map(str, argv)), return_code=code,
                   wall_seconds=time.monotonic() - start,
                   descendant_leak=leftover, process_group=process.pid,
                   group_closed=not group_members(process.pid), log_sha256=digest(log))
    if stderr:
        receipt.update(stderr_path=str(stderr), stderr_sha256=digest(stderr))
    Path(str(log) + ".receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if leftover or code != expected:
        raise ValueError(f"child exit/leak mismatch, see{log}: exit={code}, descendants={leftover}")
    return code


def closed_log(path, allow_empty=False):
    data = Path(path).read_bytes()
    if len(data) > LOG_LIMIT or (not data and not allow_empty) or (data and not data.endswith(b"\n")):
        raise ValueError(f"truncated/empty/oversized closed log: {path}")
    return data.decode("utf-8")


def run_case(case, variant, args, deadline):
    out = args.out / f"case{case}"
    out.mkdir(mode=0o700)
    image_src = FIXTURES / variant["image"]
    elf_src = FIXTURES / f"pverrw-c{case}.elf"
    before = {str(path): digest(path) for path in (image_src, elf_src)}
    image, elf = out / "image.bin", out / "image.elf"
    for src, dest in ((image_src, image), (elf_src, elf)):
        shutil.copyfile(src, dest)
        if digest(dest) != before[str(src)]:
            raise ValueError("input changed during private copy")
    sym = symbols(elf)
    validate_variant(variant, sym)
    bios = image.read_bytes()
    if len(bios) != 65536:
        raise ValueError("prebuilt BIOS must be exactly64KiB")
    if case <= 8:
        free_rc = command([QEMU, "-display", "none", "-machine", "pc", "-cpu", "pentium",
                           "-m", "32", "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04",
                           "-bios", image], out / "free-qemu.log", 30, deadline, 133)
        q_rc = command([sys.executable, "-B", REPO / "verif/qemu-trace/gen_trace.py",
                        "--qemu", QEMU, "--system", "--image", image, "--image-mode", "bios",
                        "--cpu", "pentium", "--max-insn", str(MAX_INSN), "--port",
                        str(args.port_base + case), "--out", out / "qemu.vtrace"],
                       out / "qemu.log", 90, deadline, 0)
        golden = read_complete_trace(out / "qemu.vtrace")
        grade_golden(golden, (out / "qemu.log").read_text(), sym, variant, bios, q_rc, free_rc)
    rc = command([args.tb, "--cosim", "--system", "--image", image,
                  "--max-insn", str(MAX_INSN), "--max-cycles", "1000000",
                  "--quiesce", "400", "--out", out / "rtl.vtrace", "+ven_faultlog"],
                 out / "rtl.stdout", 60, deadline, 133, stderr=out / "rtl.stderr")
    native = read_complete_trace(out / "rtl.vtrace")
    # Do not splice buffered simulator stdout with testbench stderr in flight.
    # Both regular files are closed and their owner group reaped before this
    # grading-only concatenation; each stream must independently be complete.
    native_log = closed_log(out / "rtl.stdout", allow_empty=True) + closed_log(out / "rtl.stderr")
    receipt = grade_native(native, native_log, sym, variant, bios, rc)
    if case <= 8:
        command([sys.executable, "-B", REPO / "verif/diff/compare.py", "--mode", "func", "--all",
                 out / "qemu.vtrace", out / "rtl.vtrace"], out / "diff.log", 30, deadline, 0)
    for path, value in before.items():
        pin(path, value)
    for path in (image, elf):
        pin(path, before[str(image_src if path == image else elf_src)])
    receipt.update(oracle="Intel-spec only" if case >= 9 else "pinned QEMU full architectural differential",
                   inputs=before, tb_sha256=args.tb_sha256, compile_sha256=args.compile_sha256,
                   trace_sha256=digest(out / "rtl.vtrace"),
                   stdout_sha256=digest(out / "rtl.stdout"), stderr_sha256=digest(out / "rtl.stderr"))
    if case <= 8:
        receipt.update(qemu_trace_sha256=digest(out / "qemu.vtrace"),
                       diff_log_sha256=digest(out / "diff.log"))
    (out / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tb", type=Path, required=True)
    parser.add_argument("--tb-sha256", required=True)
    parser.add_argument("--compile-record", type=Path)
    parser.add_argument("--compile-sha256", required=True)
    parser.add_argument("--compile-cwd", type=Path, default=REPO / "verif/tb")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--cases", default="all")
    parser.add_argument("--jobs", type=int, choices=range(1, 5), default=1)
    parser.add_argument("--port-base", type=int, default=41470)
    return parser.parse_args()


def main():
    args = parse_arguments()
    cases = parse_cases(args.cases)
    args.tb = args.tb.resolve(strict=True)
    args.compile_record = (args.compile_record or
                           args.tb.parent / "Vventium_top__verFiles.dat").resolve(strict=True)
    args.out = safe_output(args.out)
    if not 1024 <= args.port_base <= 65525:
        raise ValueError("port-base must permit ten distinct unprivileged ports")
    defines = validate_build(args.tb, args.tb_sha256, args.compile_record,
                             args.compile_sha256, cases, args.compile_cwd)
    pin(QEMU, QEMU_SHA)
    manifest = json.loads((FIXTURES / "manifest.json").read_text())
    if (manifest["exit_code"] != 133 or manifest["max_insn"] != MAX_INSN
            or manifest["image_bytes"] != 65536):
        raise ValueError("unreviewed global fixture contract")
    variants = {item["case"]: item for item in manifest["variants"]}
    if len(variants) != len(manifest["variants"]):
        raise ValueError("duplicate manifest variants")
    paths = [Path(__file__).resolve(), args.tb, args.compile_record, QEMU,
             FIXTURES / "manifest.json", FIXTURES / "pverrw.S", FIXTURES / "pverrw.ld",
             REPO / "verif/qemu-trace/gen_trace.py", REPO / "verif/diff/compare.py",
             REPO / "verif/diff/tracefmt.py", REPO / "verif/sys/check_faultlog.py",
             REPO / "tools/build_scope.sh"]
    for case in cases:
        item = variants[case]
        if item["image"] != f"pverrw-c{case}.bin":
            raise ValueError("unexpected image path in fixture contract")
        paths += [FIXTURES / item["image"], FIXTURES / f"pverrw-c{case}.elf"]
        validate_variant(item, symbols(paths[-1]))
    before = {str(path): digest(path) for path in paths}
    ensure_guard()
    deadline = time.monotonic() + 530  # outer hard timeout540s + scope cleanup
    args.out.mkdir(mode=0o700)
    (args.out / "inputs.json").write_text(json.dumps(before, indent=2) + "\n")
    print(f"P VERR/VERW artifacts: {args.out}", flush=True)
    results, errors = [], []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_case, case, variants[case], args, deadline): case for case in cases}
        for future in as_completed(futures):
            try:
                results.append(future.result())
            except Exception as error:
                errors.append(dict(case=futures[future], error=str(error)))
    for path, value in before.items():
        pin(path, value)
    summary = dict(result="FAIL" if errors else "PASS", cases=cases, jobs=args.jobs,
                   errors=errors, results=sorted(results, key=lambda item: item["case"]),
                   defines=defines, inputs_stable=True,
                   qualification="Directed ISA only; no cold OS or standard-suite claim.")
    (args.out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if errors:
        raise ValueError(f"selected cases failed: {errors!r}")
    print(f"PVERRW-GATE-OK: cases={cases}; exact exits/full states, not standard-suite acceptance")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, IndexError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"PVERRW-GATE-FAIL: {error}")
