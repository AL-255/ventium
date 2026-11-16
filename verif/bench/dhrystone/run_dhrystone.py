#!/usr/bin/env python3
"""Build and run bare-metal 32-bit protected-mode Dhrystone 2.1 on Ventium.

Safeguards (AGENTS.md):
  - All build/run scratch and artifacts must live under an external TMPDIR
    (e.g. /home/yukidama/external/tmp/...), never inside the repository, /tmp,
    or $HOME.
  - Evaluates an existing prebuilt Verilator `tb_ventium` binary in
    U/V + system fast-pipeline + L1/AXI mode (`--cycle --system --cosim --l1-axi`).
  - Verifies 20 post-loop Reinhold Weicker invariants, zero fault deliveries,
    real AXI backing memory fills, and real paired V-pipe retirements.
  - Synthetic microbenchmark only: never substitutes for verified physical
    Quake gameplay IPC (0.515778001 on board-qualified image c0e3fe43).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(REPO / "verif/sys"))
try:
    import check_faultlog  # type: ignore[import-not-found]
except ModuleNotFoundError:
    check_faultlog = None

VAX_11_780_DHRY_PER_SEC = 1757.0

BASE_CFLAGS = [
    "-m32",
    "-mno-80387",
    "-mno-mmx",
    "-mno-sse",
    "-ffreestanding",
    "-fno-builtin",
    "-fno-lto",
    "-fno-pic",
    "-fno-pie",
    "-fno-stack-protector",
    "-fno-asynchronous-unwind-tables",
    "-fcf-protection=none",
    "-std=gnu89",
    "-Wall",
    "-Wno-implicit-int",
    "-Wno-implicit-function-declaration",
    "-Wno-return-type",
    "-Wno-builtin-declaration-mismatch",
    "-DDHRY_EMBEDDED",
]

# Compiler profiles:
#   1. z486_report: exact flags documented in nand2mario's z486 technical report
#      cross-core comparison table (-O3 -fno-inline, no LTO, no REG, i386 ISA).
#   2. z486_makefile: exact flags in nand2mario/z486/tests/dhrystone/Makefile
#      (-O2 -march=i386 -DREG=register).
#   3. i486_o3_noinline: -O3 -fno-inline with -march=i486 -mtune=i486 (no REG).
#   4. i486_o2: -O2 with -march=i486 -mtune=i486 -DREG=register.
#   5. pentium_o3_noinline: -O3 -fno-inline with -march=pentium -mtune=pentium
#      (no REG; Weicker no-inlining ground rule + Pentium U/V scheduling).
#   6. pentium_o2: -O2 with -march=pentium -mtune=pentium -DREG=register.
PROFILES: dict[str, list[str]] = {
    "z486_report": ["-march=i386", "-O3", "-fno-inline"],
    "z486_makefile": ["-march=i386", "-O2", "-DREG=register"],
    "i486_o3_noinline": ["-march=i486", "-mtune=i486", "-O3", "-fno-inline"],
    "i486_o2": ["-march=i486", "-mtune=i486", "-O2", "-DREG=register"],
    "pentium_o3_noinline": ["-march=pentium", "-mtune=pentium", "-O3", "-fno-inline"],
    "pentium_o2": ["-march=pentium", "-mtune=pentium", "-O2", "-DREG=register"],
}

C_SOURCES = ["dhry_1.c", "dhry_2.c", "dhrystone_port.c", "support.c"]


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run_cmd(
    argv: list[str],
    log_path: Path,
    *,
    env: dict[str, str] | None = None,
    timeout: int = 180,
    allowed_rc: tuple[int, ...] = (0,),
) -> int:
    with log_path.open("wb") as out_stream:
        proc = subprocess.Popen(
            argv,
            stdout=out_stream,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
        )
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            import signal

            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            raise
    if rc not in allowed_rc:
        tail = "\n".join(log_path.read_text(errors="replace").splitlines()[-30:])
        raise RuntimeError(
            f"command failed (rc={rc}, allowed={allowed_rc}): {argv}\n{tail}"
        )
    return rc


def run_cmd_split(
    argv: list[str],
    stdout_path: Path,
    stderr_path: Path,
    *,
    env: dict[str, str] | None = None,
    timeout: int = 180,
    allowed_rc: tuple[int, ...] = (0,),
) -> int:
    with stdout_path.open("wb") as out_s, stderr_path.open("wb") as err_s:
        proc = subprocess.Popen(
            argv,
            stdout=out_s,
            stderr=err_s,
            env=env,
            start_new_session=True,
        )
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            import signal

            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            raise
    if rc not in allowed_rc:
        tail = "\n".join(
            (
                stdout_path.read_text(errors="replace")
                + "\n"
                + stderr_path.read_text(errors="replace")
            ).splitlines()[-30:]
        )
        raise RuntimeError(
            f"command failed (rc={rc}, allowed={allowed_rc}): {argv}\n{tail}"
        )
    return rc


def inspect_verilator_stamp(binary: Path) -> dict[str, object]:
    stamp = binary.parent / "Vventium_top__verFiles.dat"
    if not stamp.is_file():
        raise FileNotFoundError(f"missing Verilator stamp next to binary: {stamp}")
    cmd_line = next(
        (line for line in stamp.read_text().splitlines() if line.startswith("C ")),
        None,
    )
    if cmd_line is None:
        raise ValueError(f"no command record in {stamp}")
    defines = sorted(set(re.findall(r"\+define\+(\w+)", cmd_line)))
    def_set = set(defines)
    required = {
        "VEN_L1_AXI",
        "VEN_FE_PIPE",
        "VEN_SYS_FASTPATH",
        "VEN_SYS_FASTPATH_RELOC",
        "VEN_SYS_FASTLOAD_FLAT",
        "VEN_SYS_FASTSTORE_FLAT",
        "VEN_P54_INT_EXEC_OCC",
    }
    forbidden = {
        "VEN_UOPCACHE",
        "VEN_CACHE_HALF",
        "VEN_IC_NARROWB",
        "VTM_NO_DPI",
        "SYNTHESIS",
        "VEN_SYS_FASTPATH_ALL",
    }
    missing = sorted(required - def_set)
    present_forbidden = sorted(forbidden & def_set)
    if missing:
        raise ValueError(f"model missing required UV/fast-pipe defines: {missing}")
    if present_forbidden:
        raise ValueError(f"model has forbidden defines: {present_forbidden}")
    if " --assert " not in cmd_line:
        raise ValueError("model was not built with --assert")
    return {
        "stamp_path": str(stamp),
        "stamp_sha256": sha256(stamp),
        "define_count": len(defines),
        "defines": defines,
    }


def build_bios_image(
    cc: Path,
    profile: str,
    runs: int,
    warmup: int,
    paging: int,
    work_dir: Path,
    env: dict[str, str],
) -> dict[str, object]:
    work_dir.mkdir(parents=True, exist_ok=False)
    profile_flags = PROFILES[profile]
    cflags = [
        *BASE_CFLAGS,
        *profile_flags,
        f"-DDHRY_ITERS={runs}",
        f"-DDHRY_WARMUP_ITERS={warmup}",
        f'-DDHRY_PROFILE_NAME="{profile}"',
        f"-I{HERE}",
    ]
    objects: list[Path] = []
    boot_obj = work_dir / "boot_bios.o"
    run_cmd(
        [
            str(cc),
            "-m32",
            f"-DDHRY_PAGING={paging}",
            "-c",
            str(HERE / "boot_bios.S"),
            "-o",
            str(boot_obj),
        ],
        work_dir / "boot_bios.compile.log",
        env=env,
    )
    objects.append(boot_obj)

    for src_name in C_SOURCES:
        obj = work_dir / (Path(src_name).stem + ".o")
        run_cmd(
            [str(cc), *cflags, "-c", str(HERE / src_name), "-o", str(obj)],
            work_dir / f"{src_name}.compile.log",
            env=env,
        )
        objects.append(obj)

    elf_path = work_dir / "dhrystone.elf"
    bin_path = work_dir / "dhrystone.bin"
    run_cmd(
        [
            "ld",
            "-m",
            "elf_i386",
            "-T",
            str(HERE / "link.ld"),
            "-Map",
            str(work_dir / "dhrystone.map"),
            "-o",
            str(elf_path),
            *[str(o) for o in objects],
        ],
        work_dir / "link.log",
        env=env,
    )
    run_cmd(
        ["objcopy", "-O", "binary", str(elf_path), str(bin_path)],
        work_dir / "objcopy.log",
        env=env,
    )
    raw = bin_path.read_bytes()
    if len(raw) > 65536:
        raise ValueError(f"BIOS image exceeds 64 KiB: {len(raw)} bytes")
    if len(raw) < 65536:
        bin_path.write_bytes(raw + b"\x00" * (65536 - len(raw)))
    run_cmd(
        ["objdump", "-drwC", "-Mintel", str(elf_path)],
        work_dir / "dhrystone.disasm",
        env=env,
    )
    return {
        "profile": profile,
        "cflags": cflags,
        "runs": runs,
        "warmup": warmup,
        "paging": bool(paging),
        "elf": str(elf_path),
        "elf_sha256": sha256(elf_path),
        "bin": str(bin_path),
        "bin_sha256": sha256(bin_path),
    }


def parse_guest_console(text: str, expected_runs: int, expected_warmup: int) -> dict[str, object]:
    cfg_m = re.findall(
        r"^DHRY-CONFIG profile=(\S+) reg=([01]) warmup=(\d+) runs=(\d+)$",
        text,
        re.M,
    )
    state_m = re.findall(
        r"^DHRY-STATE Int_Glob=(-?\d+) Bool_Glob=(-?\d+) Ch_1_Glob=(.) Ch_2_Glob=(.) "
        r"Arr1_8=(-?\d+) Arr2_8_7=(-?\d+) Ptr_Int=(-?\d+) NextPtr_Int=(-?\d+)$",
        text,
        re.M,
    )
    tsc_ep_m = re.findall(
        r"^DHRY-TSC start=([0-9a-f]{8}):([0-9a-f]{8}) stop=([0-9a-f]{8}):([0-9a-f]{8})$",
        text,
        re.M,
    )
    tsc_d_m = re.findall(
        r"^DHRY-TSC delta=([0-9a-f]{8}):([0-9a-f]{8}) runs=(\d+)$",
        text,
        re.M,
    )
    if len(cfg_m) != 1 or len(state_m) != 1 or len(tsc_ep_m) != 1 or len(tsc_d_m) != 1:
        raise ValueError(f"malformed or incomplete guest console output:\n{text}")
    if "DHRY-SELFCHECK PASS\n" not in text or text.count("DHRY-END\n") != 1:
        raise ValueError(f"guest self-check did not pass:\n{text}")

    prof, reg_s, warm_s, runs_s = cfg_m[0]
    if int(warm_s) != expected_warmup or int(runs_s) != expected_runs:
        raise ValueError(f"guest config mismatch: {cfg_m[0]}")

    ig, bg, c1, c2, a1, a2, pi, npi = state_m[0]
    expected_state = (5, 1, "A", "B", 7, expected_runs + 10, 17, 18)
    actual_state = (int(ig), int(bg), c1, c2, int(a1), int(a2), int(pi), int(npi))
    if actual_state != expected_state:
        raise ValueError(f"Dhrystone state mismatch: {actual_state} != {expected_state}")

    sh, sl, eh, el = (int(x, 16) for x in tsc_ep_m[0])
    dh, dl, druns = int(tsc_d_m[0][0], 16), int(tsc_d_m[0][1], 16), int(tsc_d_m[0][2])
    start_tsc = (sh << 32) | sl
    stop_tsc = (eh << 32) | el
    delta_tsc = (dh << 32) | dl
    if druns != expected_runs or ((stop_tsc - start_tsc) & ((1 << 64) - 1)) != delta_tsc:
        raise ValueError("inconsistent start/stop/delta TSC")
    if delta_tsc <= 0:
        raise ValueError(f"non-positive delta_tsc: {delta_tsc}")

    cyc_per_dhry = delta_tsc / expected_runs
    dhry_per_sec_per_mhz = 1_000_000.0 / cyc_per_dhry
    dmips_per_mhz = dhry_per_sec_per_mhz / VAX_11_780_DHRY_PER_SEC
    return {
        "profile": prof,
        "reg_attr": bool(int(reg_s)),
        "warmup_runs": expected_warmup,
        "runs": expected_runs,
        "start_tsc": start_tsc,
        "stop_tsc": stop_tsc,
        "delta_tsc": delta_tsc,
        "cycles_per_dhrystone": cyc_per_dhry,
        "dhrystones_per_sec_per_mhz": dhry_per_sec_per_mhz,
        "dmips_per_mhz": dmips_per_mhz,
        "dmips_at_40mhz_sta": dmips_per_mhz * 40.0,
        "dmips_at_62_5mhz_empirical": dmips_per_mhz * 62.5,
        "selfcheck_pass": True,
    }


def run_qemu_smoke(qemu: Path, bin_path: Path, runs: int, warmup: int, work_dir: Path, env: dict[str, str]) -> dict[str, object]:
    dbg_log = work_dir / "qemu_debugcon.log"
    run_cmd(
        [
            str(qemu),
            "-machine",
            "pc",
            "-accel",
            "tcg",
            "-cpu",
            "pentium",
            "-m",
            "16",
            "-bios",
            str(bin_path),
            "-display",
            "none",
            "-serial",
            "none",
            "-monitor",
            "none",
            "-no-reboot",
            "-no-shutdown",
            "-debugcon",
            f"file:{dbg_log}",
            "-global",
            "isa-debugcon.iobase=0xe9",
            "-device",
            "isa-debug-exit,iobase=0xf4,iosize=0x04",
        ],
        work_dir / "qemu.log",
        env=env,
        timeout=60,
        allowed_rc=(33,),
    )
    parsed = parse_guest_console(dbg_log.read_text(), runs, warmup)
    return {
        "native_exit": 33,
        "selfcheck_pass": parsed["selfcheck_pass"],
        "qemu_tsc_not_processor_cycles": True,
    }


def run_verilator(
    binary: Path,
    bin_path: Path,
    runs: int,
    warmup: int,
    work_dir: Path,
    env: dict[str, str],
    *,
    axi_rlat: int = 0,
    axi_wlat: int = 0,
    cpu_pin: int | None = None,
) -> dict[str, object]:
    total_iters = warmup + runs
    max_insn = max(4_000_000, total_iters * 1200 + 250_000)
    max_cycles = max(10_000_000, total_iters * 4000 + 500_000)
    argv: list[str] = []
    if cpu_pin is not None:
        argv += ["taskset", "-c", str(cpu_pin)]
    argv += [
        str(binary),
        "--cycle",
        "--system",
        "--cosim",
        "--l1-axi",
        "--no-trace",
        "--image",
        str(bin_path),
        "--max-insn",
        str(max_insn),
        "--max-cycles",
        str(max_cycles),
        "--quiesce",
        "200000",
        "+ven_faultlog",
    ]
    run_env = dict(env)
    run_env["AXI_RLAT"] = str(axi_rlat)
    run_env["AXI_WLAT"] = str(axi_wlat)

    log_path = work_dir / f"verilator_rlat{axi_rlat}_wlat{axi_wlat}.stdout.log"
    err_path = work_dir / f"verilator_rlat{axi_rlat}_wlat{axi_wlat}.stderr.log"
    t0 = time.monotonic()
    rc = run_cmd_split(argv, log_path, err_path, env=run_env, timeout=300, allowed_rc=(33,))
    wall_s = time.monotonic() - t0

    stdout_text = log_path.read_text(errors="replace")
    stderr_text = err_path.read_text(errors="replace")
    log_text = stdout_text + "\n" + stderr_text
    if re.search(r"%Error|%Fatal|Assertion failed|tb: FLT", log_text):
        raise RuntimeError(f"RTL fault/error detected in {log_path}")
    if check_faultlog is not None:
        check_faultlog.check_counts(check_faultlog.read_counts(stdout_text.splitlines()), {})
    elif re.search(r"VEN[-_]FAULT", stdout_text):
        raise RuntimeError(f"Unexpected faultlog event in {log_path}")

    guest_lines = [
        line
        for line in log_text.splitlines()
        if line.startswith(("VENTIUM DHRYSTONE", "DHRY-"))
    ]
    parsed = parse_guest_console("\n".join(guest_lines) + "\n", runs, warmup)

    ret_m = re.findall(r"retires\s+(\d+)\s+\(U=(\d+)\s+pairedV=(\d+)\)", log_text)
    clocks_m = re.findall(r"^\s*clocks\s+(\d+)\s*$", log_text, re.M)
    l1_fill_m = re.findall(
        r"\[L1DPERF\] fill cycles=(\d+) backing-wait=(\d+) backing-ack=(\d+)",
        log_text,
    )
    l1_hit_m = re.findall(
        r"\[L1DPERF\] hit-capture=(\d+) hit-ack=(\d+) critical-ack=(\d+) "
        r"hit-under-fill=(\d+) fill-forward=(\d+) miss-start=(\d+) bypass-start=(\d+)",
        log_text,
    )
    tb_m = re.findall(
        r"tb: retired (\d+) instructions in (\d+) clocks \(bus: (\d+) reads, (\d+) writes\)",
        log_text,
    )
    if len(ret_m) != 1 or len(l1_fill_m) != 1 or len(l1_hit_m) != 1 or len(tb_m) != 1:
        raise RuntimeError(f"missing performance/L1 counters in {log_path}")

    tot_ret, u_ret, v_ret = map(int, ret_m[0])
    fill_cyc, fill_wait, fill_ack = map(int, l1_fill_m[0])
    hit_cap, hit_ack, crit_ack, huf, ffwd, miss_start, bypass_start = map(int, l1_hit_m[0])
    tb_ret, tb_clocks, bus_reads, bus_writes = map(int, tb_m[0])

    if tot_ret != u_ret + v_ret or tot_ret != tb_ret:
        raise RuntimeError(f"inconsistent retire counts: {ret_m[0]} vs tb {tb_ret}")
    if v_ret <= 0:
        raise RuntimeError("pairedV is zero — dual-issue V-pipe did not engage!")
    if fill_ack <= 0:
        raise RuntimeError("L1DPERF backing-ack is zero — L1/AXI backing did not engage!")

    parsed.update(
        {
            "native_exit": rc,
            "wall_seconds": wall_s,
            "axi_rlat": axi_rlat,
            "axi_wlat": axi_wlat,
            "whole_run_clocks": int(clocks_m[0]) if clocks_m else tb_clocks,
            "whole_run_retires_total": tot_ret,
            "whole_run_retires_u": u_ret,
            "whole_run_retires_paired_v": v_ret,
            "whole_run_v_share_of_retires": v_ret / tot_ret,
            "whole_run_pair_rate_of_groups": v_ret / u_ret,
            "l1d_hit_ack": hit_ack,
            "l1d_miss_start": miss_start,
            "l1d_bypass_start": bypass_start,
            "l1d_fill_cycles": fill_cyc,
            "l1d_backing_ack": fill_ack,
            "bus_reads": bus_reads,
            "bus_writes": bus_writes,
            "log_path": str(log_path),
        }
    )
    return parsed


def compute_marginal_loop(low: dict[str, object], high: dict[str, object]) -> dict[str, object]:
    d_runs = int(high["runs"]) - int(low["runs"])
    if d_runs <= 0:
        raise ValueError("high runs must exceed low runs")
    d_tsc = int(high["delta_tsc"]) - int(low["delta_tsc"])
    d_tot = int(high["whole_run_retires_total"]) - int(low["whole_run_retires_total"])
    d_u = int(high["whole_run_retires_u"]) - int(low["whole_run_retires_u"])
    d_v = int(high["whole_run_retires_paired_v"]) - int(low["whole_run_retires_paired_v"])
    d_clocks = int(high["whole_run_clocks"]) - int(low["whole_run_clocks"])

    cyc_per_dhry = d_tsc / d_runs
    dhry_per_sec_per_mhz = 1_000_000.0 / cyc_per_dhry
    dmips_per_mhz = dhry_per_sec_per_mhz / VAX_11_780_DHRY_PER_SEC
    insns_per_dhry = d_tot / d_runs
    u_per_dhry = d_u / d_runs
    v_per_dhry = d_v / d_runs
    cpi_uv = d_tsc / d_tot
    ipc_uv = d_tot / d_tsc
    ipc_u_only = d_u / d_tsc

    return {
        "delta_runs": d_runs,
        "delta_tsc": d_tsc,
        "delta_whole_run_clocks": d_clocks,
        "cycles_per_dhrystone": cyc_per_dhry,
        "dhrystones_per_sec_per_mhz": dhry_per_sec_per_mhz,
        "dmips_per_mhz": dmips_per_mhz,
        "dmips_at_40mhz_sta": dmips_per_mhz * 40.0,
        "dmips_at_62_5mhz_empirical": dmips_per_mhz * 62.5,
        "retires_total_per_dhrystone": insns_per_dhry,
        "retires_u_per_dhrystone": u_per_dhry,
        "retires_paired_v_per_dhrystone": v_per_dhry,
        "v_share_of_retires_pct": 100.0 * d_v / d_tot,
        "pair_rate_of_issue_groups_pct": 100.0 * d_v / d_u,
        "loop_cpi_total_uv": cpi_uv,
        "loop_ipc_total_uv": ipc_uv,
        "loop_ipc_primary_u_only": ipc_u_only,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--binary", type=Path, required=True, help="prebuilt Verilator tb_ventium")
    ap.add_argument("--out", type=Path, required=True, help="new output directory under external TMPDIR")
    ap.add_argument(
        "--profiles",
        nargs="+",
        choices=list(PROFILES),
        default=["z486_report", "z486_makefile", "pentium_o3_noinline", "pentium_o2"],
    )
    ap.add_argument("--low-runs", type=int, default=200)
    ap.add_argument("--high-runs", type=int, default=2200)
    ap.add_argument("--warmup", type=int, default=20)
    ap.add_argument("--paging", type=int, choices=(0, 1), default=1)
    ap.add_argument("--cc", type=Path, default=Path("/usr/bin/x86_64-linux-gnu-gcc-13"))
    ap.add_argument(
        "--qemu",
        type=Path,
        default=Path("/usr/bin/qemu-system-i386"),
    )
    ap.add_argument("--skip-qemu", action="store_true")
    ap.add_argument("--axi-rlat", type=int, default=0)
    ap.add_argument("--axi-wlat", type=int, default=0)
    ap.add_argument("--cpu-pin", type=int, default=None)
    args = ap.parse_args()

    if "TMPDIR" not in os.environ:
        raise RuntimeError("TMPDIR must be set explicitly to external scratch (e.g. /home/yukidama/external/tmp)")
    tmpdir = Path(os.environ["TMPDIR"]).resolve(strict=True)
    out = args.out.resolve()
    if out == REPO or REPO in out.parents:
        raise RuntimeError(f"--out must be outside the repository: {out}")
    if not out.is_relative_to(tmpdir):
        raise RuntimeError(f"--out ({out}) must reside inside TMPDIR ({tmpdir})")
    if out.exists():
        raise RuntimeError(f"--out must not already exist: {out}")
    if shutil.disk_usage(tmpdir).free < 512 * 1024**2:
        raise RuntimeError("insufficient free space on TMPDIR (<512 MiB)")

    binary = args.binary.resolve(strict=True)
    cc = args.cc.resolve(strict=True)
    stamp_info = inspect_verilator_stamp(binary)

    out.mkdir(parents=True)
    tmp_sub = out / "tmp"
    tmp_sub.mkdir()
    clean_env = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith(("VEN_", "VENTIUM_", "TB_", "AXI_", "QEMU_"))
    }
    clean_env["TMPDIR"] = str(tmp_sub)
    clean_env["PYTHONDONTWRITEBYTECODE"] = "1"

    cc_version = subprocess.check_output([str(cc), "--version"], text=True).splitlines()[0]
    summary: dict[str, object] = {
        "schema": "ventium-dhrystone-2.1-v1",
        "microbenchmark_only": True,
        "not_gameplay_ipc": True,
        "verified_hardware_gameplay_ipc_baseline": {
            "image": "c0e3fe43",
            "total_uv_ipc": 0.515778001,
            "primary_u_ipc": 0.397847833,
            "cycles_window": "28,696,827,616-32,989,404,795",
        },
        "binary": str(binary),
        "binary_sha256": sha256(binary),
        "verilator_stamp": stamp_info,
        "compiler": str(cc),
        "compiler_version": cc_version,
        "vax_11_780_divisor": VAX_11_780_DHRY_PER_SEC,
        "paging_enabled": bool(args.paging),
        "warmup_runs": args.warmup,
        "low_runs": args.low_runs,
        "high_runs": args.high_runs,
        "axi_rlat": args.axi_rlat,
        "axi_wlat": args.axi_wlat,
        "profiles": {},
    }

    for profile in args.profiles:
        prof_dir = out / profile
        prof_dir.mkdir()
        low_build = build_bios_image(
            cc, profile, args.low_runs, args.warmup, args.paging, prof_dir / f"build_{args.low_runs}", clean_env
        )
        high_build = build_bios_image(
            cc, profile, args.high_runs, args.warmup, args.paging, prof_dir / f"build_{args.high_runs}", clean_env
        )

        qemu_res = None
        if not args.skip_qemu and args.qemu.is_file():
            qemu_res = run_qemu_smoke(
                args.qemu.resolve(strict=True),
                Path(low_build["bin"]),
                args.low_runs,
                args.warmup,
                prof_dir / f"build_{args.low_runs}",
                clean_env,
            )

        low_run = run_verilator(
            binary,
            Path(low_build["bin"]),
            args.low_runs,
            args.warmup,
            prof_dir / f"build_{args.low_runs}",
            clean_env,
            axi_rlat=args.axi_rlat,
            axi_wlat=args.axi_wlat,
            cpu_pin=args.cpu_pin,
        )
        high_run = run_verilator(
            binary,
            Path(high_build["bin"]),
            args.high_runs,
            args.warmup,
            prof_dir / f"build_{args.high_runs}",
            clean_env,
            axi_rlat=args.axi_rlat,
            axi_wlat=args.axi_wlat,
            cpu_pin=args.cpu_pin,
        )
        marginal = compute_marginal_loop(low_run, high_run)

        row = {
            "cflags": low_build["cflags"],
            "qemu_smoke": qemu_res,
            "low_run": low_run,
            "high_run": high_run,
            "steady_marginal": marginal,
        }
        summary["profiles"][profile] = row
        print(
            json.dumps(
                {
                    "profile": profile,
                    "high_runs": args.high_runs,
                    "high_dmips_per_mhz": round(float(high_run["dmips_per_mhz"]), 6),
                    "steady_dmips_per_mhz": round(float(marginal["dmips_per_mhz"]), 6),
                    "cycles_per_dhrystone": round(float(marginal["cycles_per_dhrystone"]), 4),
                    "insns_per_dhrystone": round(float(marginal["retires_total_per_dhrystone"]), 2),
                    "loop_ipc_uv": round(float(marginal["loop_ipc_total_uv"]), 6),
                    "loop_ipc_u_only": round(float(marginal["loop_ipc_primary_u_only"]), 6),
                    "v_share_pct": round(float(marginal["v_share_of_retires_pct"]), 2),
                }
            ),
            flush=True,
        )

    (out / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
