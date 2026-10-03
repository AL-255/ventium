#!/usr/bin/env python3
"""Run the source-extracted RC/PC selector equivalence microgate."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import resource
import subprocess
import sys
import tempfile


NEW_SHA256 = "e093df1b7b332a226a2ad8a551af2309403610fb15ef3cd791afcdf06c952b5a"
OLD_SHA256 = "19a2b6e4323ce6583567632baf4358b5af62406775ef0c1a8cf8e0754760b70c"
FROZEN_COMMIT = "4f7f858fd38f7453cdfcc4619cec888d9a638356"
FROZEN_REPO_PATH = "fp_shared/ven_fp_top.sv"
MAX_SECONDS = 120
MAX_BYTES = 512 * 1024 * 1024


def fail(message: str) -> None:
    raise RuntimeError(message)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def require_regular(path: Path, label: str) -> None:
    if not path.is_file() or path.is_symlink():
        fail(f"{label} must be a regular non-symlink file: {path}")


def read_frozen(repo: Path, requested: Path | None) -> tuple[bytes, str]:
    """Return a pinned historical file, never a handwritten reference model."""
    if requested is not None:
        # Check the user-supplied leaf before resolve(), so a symlink cannot
        # silently redirect the frozen selector input.
        if requested.is_symlink():
            fail(f"explicit frozen source must not be a symlink: {requested}")
        require_regular(requested, "explicit frozen source")
        source = requested.resolve(strict=True)
        require_regular(source, "explicit frozen source")
        return source.read_bytes(), f"file:{source}"
    completed = subprocess.run(
        ["git", "-C", str(repo), "show", "--no-ext-diff",
         f"{FROZEN_COMMIT}:{FROZEN_REPO_PATH}"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        fail(f"cannot read pinned frozen source {FROZEN_COMMIT}:{FROZEN_REPO_PATH}: {detail}")
    return completed.stdout, f"git:{FROZEN_COMMIT}:{FROZEN_REPO_PATH}"


def unique_between(text: str, begin: str, end: str, label: str) -> str:
    first = text.find(begin)
    if first < 0:
        fail(f"{label}: start anchor missing")
    if text.find(begin, first + len(begin)) >= 0:
        fail(f"{label}: start anchor is not unique")
    last = text.find(end, first + len(begin))
    if last < 0:
        fail(f"{label}: end anchor missing")
    return text[first:last]


def unique_function(text: str, signature: str, label: str) -> str:
    first = text.find(signature)
    if first < 0 or text.find(signature, first + len(signature)) >= 0:
        fail(f"{label}: function anchor missing or non-unique")
    last = text.find("  endfunction", first)
    if last < 0:
        fail(f"{label}: function end missing")
    return text[first:last + len("  endfunction")]


def one_line(text: str, line: str, label: str) -> str:
    count = text.count(line)
    if count != 1:
        fail(f"{label}: expected one matching line, found {count}")
    return line


def command_ready_fragments(text: str, label: str) -> tuple[str, str, str, str]:
    interval = unique_between(
        text,
        "  wire logic arith_mul_interval_busy = arith_mul_accepted_last_cycle &&\n",
        "\n  logic [2:0] arith_cmd_dst;",
        f"{label} interval-ready expression",
    )
    eligible = unique_between(
        text,
        "  assign arith_stream_eligible = !cmd_pop && !issue_stack_fault &&\n",
        "\n  assign cmd_ready = !arith_mul_interval_busy &&",
        f"{label} stream-eligible expression",
    )
    stream_ready = unique_between(
        text,
        "  assign cmd_ready = !arith_mul_interval_busy &&\n",
        "\n  always_ff @(posedge clk) begin",
        f"{label} stream cmd_ready expression",
    )
    idle_ready = one_line(
        text,
        "  assign cmd_ready = (top_state == TOP_IDLE);",
        f"{label} non-stream cmd_ready expression",
    )
    return interval, eligible, stream_ready, idle_ready


def check_source_layout(text: str, label: str, split: bool) -> dict[str, str]:
    enum = "\n".join((
        "  typedef enum logic [2:0] {",
        "    TOP_IDLE, TOP_ALU, TOP_SRT, TOP_MISC, TOP_BCD_LOAD, TOP_BCD_STORE,",
        "    TOP_TRANS",
        "  } top_state_t;",
    ))
    if enum not in text:
        fail(f"{label}: TOP state encoding/layout changed")
    accept = one_line(text, "  wire logic accept = cmd_valid & cmd_ready;", f"{label} accept")
    is_div = unique_function(
        text,
        "  function automatic logic is_div_arith(input logic [2:0] op);",
        f"{label} is_div_arith",
    )
    is_fast = unique_function(
        text,
        "  function automatic logic is_fast_arith(input logic [2:0] op);",
        f"{label} is_fast_arith",
    )
    interval, eligible, stream_ready, idle_ready = command_ready_fragments(text, label)
    start_anchor = "  always_comb begin\n    srt_start = 1'b0;\n    srt_mode  = 2'd0;\n"
    end_anchor = "\n\n  // All architectural mutation is concentrated in this commit decoder."
    result = {
        "accept": accept, "is_div": is_div, "is_fast": is_fast, "interval": interval,
        "eligible": eligible, "stream_ready": stream_ready, "idle_ready": idle_ready,
    }
    if split:
        rc_anchor = "\n".join((
            "  // Rounding controls are live throughout SRT execution. Command admission",
            "  // cannot win while TOP_TRANS owns the unit (cmd_ready is low there), so",
            "  // keep its long decode/operand cone out of these controls. Do not capture",
            "  // RC/PC: a borrowed transcendental request's PC=64 override ends with the",
            "  // request pulse, retaining the existing subsequent live-CW behavior.",
            "  always_comb begin",
            "    srt_rc    = fctrl_o[11:10];",
            "    srt_pc    = fctrl_o[9:8];",
            "",
        ))
        rc_block = unique_between(text, rc_anchor, "\n" + start_anchor, f"{label} RC/PC")
        start_block = unique_between(text, start_anchor, end_anchor, f"{label} SRT start")
        if "srt_rc" in start_block or "srt_pc" in start_block:
            fail(f"{label}: split SRT start block still owns RC/PC")
        if "srt_rc  = trans_divide_rc;" not in rc_block or "srt_pc  = 2'b11;" not in rc_block:
            fail(f"{label}: split override shape changed")
        result.update({"rc_block": rc_block, "start_block": start_block})
    else:
        old_anchor = start_anchor + "    srt_rc    = fctrl_o[11:10];\n    srt_pc    = fctrl_o[9:8];\n"
        old_block = unique_between(text, old_anchor, end_anchor, f"{label} combined selector")
        if "srt_rc    = trans_divide_rc;" not in old_block or "srt_pc    = 2'b11;" not in old_block:
            fail(f"{label}: frozen override shape changed")
        result["old_block"] = old_block
    return result


PORTS = "\n".join((
    "(",
    "    input  logic [2:0]  top_state,",
    "    input  logic        cmd_valid,",
    "    input  logic [6:0]  cmd_op,",
    "    input  logic [2:0]  cmd_aluop,",
    "    input  logic [2:0]  cmd_sti,",
    "    input  logic        cmd_pop,",
    "    input  logic        issue_stack_fault,",
    "    input  logic        div_special_hit,",
    "    input  logic        sqrt_special_hit,",
    "    input  logic [15:0] fctrl_o,",
    "    input  logic [15:0] fstat_o,",
    "    input  logic        arith_mul_accepted_last_cycle,",
    "    input  logic        arith_stream_hazard,",
    "    input  logic [79:0] alu_a,",
    "    input  logic [79:0] alu_b,",
    "    input  logic [79:0] st0_data,",
    "    input  logic [79:0] sti_data,",
    "    input  logic        trans_divide_start,",
    "    input  logic [79:0] trans_divide_a,",
    "    input  logic [79:0] trans_divide_b,",
    "    input  logic [1:0]  trans_divide_rc,",
    "    input  logic        trans_done,",
    "    input  logic [79:0] trans_primary,",
    "    input  logic [79:0] trans_secondary,",
    "    input  logic [6:0]  pending_op,",
    "    input  logic        trans_c2,",
    "    output wire logic   cmd_ready,",
    "    output wire logic   accept_o,",
    "    output logic        srt_start,",
    "    output logic [1:0]  srt_mode,",
    "    output logic [1:0]  srt_rc,",
    "    output logic [1:0]  srt_pc,",
    "    output logic [79:0] srt_a,",
    "    output logic [79:0] srt_b",
    ");",
))


def wrapper(name: str, pieces: dict[str, str], split: bool, source_sha: str) -> str:
    header = "\n".join((
        f"// Generated by run_ven_fp_srt_controls.py from SHA256 {source_sha}.",
        "// Selector bodies are source-extracted; ports/types are test scaffolding.",
        f"module {name}",
        "  import ventium_decode_pkg::*;",
        PORTS,
        "  localparam logic [2:0] TOP_IDLE      = 3'd0;",
        "  localparam logic [2:0] TOP_ALU       = 3'd1;",
        "  localparam logic [2:0] TOP_SRT       = 3'd2;",
        "  localparam logic [2:0] TOP_MISC      = 3'd3;",
        "  localparam logic [2:0] TOP_BCD_LOAD  = 3'd4;",
        "  localparam logic [2:0] TOP_BCD_STORE = 3'd5;",
        "  localparam logic [2:0] TOP_TRANS     = 3'd6;",
        "",
        "  logic arith_stream_eligible;",
        "`ifdef VEN_FP_ARITH_STREAM",
        pieces["interval"],
        pieces["eligible"],
        pieces["stream_ready"],
        "`else",
        pieces["idle_ready"],
        "`endif",
        pieces["accept"],
        "  assign accept_o = accept;",
        "",
        pieces["is_fast"],
        "",
        pieces["is_div"],
        "",
    ))
    body = pieces["rc_block"] + "\n\n" + pieces["start_block"] if split else pieces["old_block"]
    return header + body + "\nendmodule\n"


def artifact_directory(requested: str | None) -> Path:
    if requested is None:
        return Path(tempfile.mkdtemp(prefix="ven-fp-srt-controls.", dir="/var/tmp"))
    path = Path(requested).resolve()
    allowed = (Path("/tmp").resolve(), Path("/var/tmp").resolve())
    if not any(path == root or root in path.parents for root in allowed):
        fail("--artifact-dir must be inside /tmp or /var/tmp")
    path.mkdir(mode=0o700, parents=True, exist_ok=False)
    return path


def bounded_preexec() -> None:
    resource.setrlimit(resource.RLIMIT_AS, (MAX_BYTES, MAX_BYTES))
    resource.setrlimit(resource.RLIMIT_CPU, (MAX_SECONDS, MAX_SECONDS))


def run_limited(command: list[str], cwd: Path) -> str:
    completed = subprocess.run(
        command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=MAX_SECONDS, check=False, preexec_fn=bounded_preexec,
    )
    if completed.returncode != 0:
        fail("command failed (exit %d): %s\n%s" % (completed.returncode, " ".join(command), completed.stdout))
    return completed.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--frozen", type=Path,
        help="optional regular non-symlink historical ven_fp_top.sv; default is the pinned git blob",
    )
    parser.add_argument("--artifact-dir")
    arguments = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    current = repo / "fp_shared" / "ven_fp_top.sv"
    testbench = repo / "fp_shared" / "tb" / "tb_ven_fp_srt_controls.sv"
    decode_pkg = repo / "rtl" / "core" / "ventium_decode_pkg.sv"
    for path, label in ((current, "current source"), (testbench, "testbench"),
                        (decode_pkg, "decode package")):
        require_regular(path, label)
    current_bytes = current.read_bytes()
    if sha256_bytes(current_bytes) != NEW_SHA256:
        fail(f"current source SHA256 mismatch: {current}")
    decode_sha = sha256(decode_pkg)
    testbench_sha = sha256(testbench)
    frozen_bytes, frozen_origin = read_frozen(repo, arguments.frozen)
    if sha256_bytes(frozen_bytes) != OLD_SHA256:
        fail(f"frozen source SHA256 mismatch: {frozen_origin}")
    old = check_source_layout(frozen_bytes.decode("utf-8"), "frozen source", False)
    new = check_source_layout(current_bytes.decode("utf-8"), "current source", True)
    for key in ("accept", "is_div", "is_fast", "interval", "eligible", "stream_ready", "idle_ready"):
        if old[key] != new[key]:
            fail(f"frozen/current {key} context differs; selector-only comparison is invalid")
    out = artifact_directory(arguments.artifact_dir)
    frozen_archive = out / "frozen_ven_fp_top.sv"
    frozen_archive.write_bytes(frozen_bytes)
    if sha256(frozen_archive) != OLD_SHA256:
        fail(f"archived frozen source SHA256 mismatch: {frozen_archive}")
    current_archive = out / "current_ven_fp_top.sv"
    current_archive.write_bytes(current_bytes)
    if sha256(current_archive) != NEW_SHA256:
        fail(f"archived current source SHA256 mismatch: {current_archive}")
    generated = out / "srt_controls_actual_extract.sv"
    generated.write_text(
        "`default_nettype none\n\n" + wrapper("srt_controls_old_actual", old, False, OLD_SHA256)
        + "\n" + wrapper("srt_controls_new_actual", new, True, NEW_SHA256)
        + "\n`default_nettype wire\n", encoding="utf-8",
    )
    generated_sha = sha256(generated)
    for variant, defines in (("base", []), ("stream", ["-DVEN_FP_ARITH_STREAM"])):
        executable = out / f"tb_ven_fp_srt_controls.{variant}.vvp"
        compile_output = run_limited(
            ["/usr/bin/iverilog", "-g2012", *defines, "-s", "tb_ven_fp_srt_controls",
             "-I", str(out), "-o", str(executable), str(decode_pkg), str(testbench)], repo)
        (out / f"compile.{variant}.log").write_text(compile_output, encoding="utf-8")
        run_output = run_limited(["/usr/bin/vvp", str(executable)], repo)
        (out / f"run.{variant}.log").write_text(run_output, encoding="utf-8")
        if "VEN-FP-SRT-CONTROLS-OK" not in run_output:
            fail(f"{variant}: completion marker missing")
        print(run_output, end="")
    if sha256(current) != NEW_SHA256:
        fail(f"current source changed during run: {current}")
    if sha256(decode_pkg) != decode_sha:
        fail(f"decode package changed during run: {decode_pkg}")
    if sha256(testbench) != testbench_sha:
        fail(f"testbench changed during run: {testbench}")
    print(
        "VEN-FP-SRT-CONTROLS-RUNNER-OK "
        f"artifact_dir={out} generated_sha256={generated_sha} "
        f"frozen_origin={frozen_origin} frozen_archive={frozen_archive} "
        f"current_archive={current_archive} decode_pkg_sha256={decode_sha} "
        f"testbench_sha256={testbench_sha} "
        f"current_sha256={NEW_SHA256} frozen_sha256={OLD_SHA256} "
        f"limit_seconds={MAX_SECONDS} limit_bytes={MAX_BYTES}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.TimeoutExpired, OSError) as error:
        print(f"VEN-FP-SRT-CONTROLS-FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
