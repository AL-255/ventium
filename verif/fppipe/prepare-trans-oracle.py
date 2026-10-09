#!/usr/bin/env python3
"""Isolate the historical FPATAN oracle from hardware-only arithmetic stubs.

The shared DUT keeps every supplied define. Only a renamed reference package
is compiled without VEN_SRT_ITER; the macro is restored before any DUT source.
No arithmetic expression or expected result is changed. Generated files belong
in a fresh, disposable directory, never in the RTL source tree.
"""
import argparse
import hashlib
import json
from pathlib import Path


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"expected exactly one {old!r}")
    return text.replace(old, new)


def prepare(source, fixture, output):
    source, fixture, output = map(lambda p: Path(p).resolve(), (source, fixture, output))
    output.mkdir(exist_ok=False)
    package = source / "rtl/fpu/fpu_x87_pkg.sv"
    reference = source / "rtl/fpu/fpu_fpatan.sv"
    pins = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (package, reference, fixture, Path(__file__).resolve())}
    text = replace_once(package.read_text(), "package fpu_x87_pkg;",
                        "package shared_fp_reference_pkg;")
    text = replace_once(text, "endpackage : fpu_x87_pkg",
                        "endpackage : shared_fp_reference_pkg")
    text = ("// Test-only oracle; DUT configuration is restored below.\n"
            "`ifdef SHARED_FP_REFERENCE_RESTORE_SRT\n"
            '  `error "private oracle macro already defined"\n'
            "`endif\n"
            "`ifdef VEN_SRT_ITER\n"
            "  `define SHARED_FP_REFERENCE_RESTORE_SRT\n"
            "  `undef VEN_SRT_ITER\n"
            "`endif\n" + text + "\n"
            "`ifdef SHARED_FP_REFERENCE_RESTORE_SRT\n"
            "  `define VEN_SRT_ITER\n"
            "  `undef SHARED_FP_REFERENCE_RESTORE_SRT\n"
            "`endif\n")
    (output / "shared_fp_reference_pkg.sv").write_text(text)
    text = replace_once(reference.read_text(), "module fpu_fpatan\n",
                        "module shared_fp_reference_atan\n")
    text = replace_once(text, "import fpu_x87_pkg::*;",
                        "import shared_fp_reference_pkg::*;")
    (output / "shared_fp_reference_atan.sv").write_text(text)
    text = replace_once(fixture.read_text(), "fpu_fpatan reference_atan (",
                        "shared_fp_reference_atan reference_atan (")
    # Leave an executable guard against the exact configuration error found in
    # the old integration flow. Also verify the hardware package remains stubbed.
    text = replace_once(text, "  int checks;", """  int checks;
  initial begin
    logic [82:0] oracle_ratio, hardware_ratio;
    oracle_ratio = shared_fp_reference_pkg::fx_div(
        80'h3f008000000000000000, 80'h40008000000000000000, 2'd0, 2'b11);
    hardware_ratio = fpu_x87_pkg::fx_div(
        80'h3f008000000000000000, 80'h40008000000000000000, 2'd0, 2'b11);
    if (oracle_ratio !== {3'b000, 80'h3eff8000000000000000})
      $fatal(1, "FP oracle divider is stubbed or incorrect");
`ifdef VEN_SRT_ITER
`ifndef VEN_DIV_EXACT
    if (hardware_ratio !== 83'd0)
      $fatal(1, "FP oracle setup changed the DUT hardware package profile");
`endif
`endif
  end""")
    (output / fixture.name).write_text(text)
    assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h
               for p, h in pins.items())
    (output / "inputs.json").write_text(json.dumps(pins, indent=2) + "\n")
    return [output / "shared_fp_reference_pkg.sv",
            output / "shared_fp_reference_atan.sv", output / fixture.name]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    for path in prepare(args.source, args.fixture, args.out):
        print(path)
