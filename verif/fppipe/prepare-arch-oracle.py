#!/usr/bin/env python3
"""Prepare the historical sequential writeback oracle, without changing DUT flags.

Compile after shared_fp_reference_pkg.sv from prepare-trans-oracle.py. The old
fixture replays separately tested deferred-engine results; this is a state/
routing check, NOT an independent arithmetic or whole-core differential gate.
"""
import argparse
import hashlib
import json
from pathlib import Path


def once(text, before, after):
    if text.count(before) != 1:
        raise ValueError(f'expected one {before!r}')
    return text.replace(before, after)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('source', 'fixture', 'out'):
        parser.add_argument('--'+name, type=Path, required=True)
    args = parser.parse_args()
    source, output = args.source.resolve(strict=True), args.out.resolve()
    inputs = [source/'rtl/core/ventium_x87_pkg.sv', source/'rtl/core/fpu_writeback.sv',
              args.fixture.resolve(strict=True), Path(__file__).resolve()]
    pins = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    output.mkdir(exist_ok=False)
    text = once(inputs[0].read_text(), 'package ventium_x87_pkg;',
                'package shared_x87_reference_pkg;')
    text = once(text, 'endpackage : ventium_x87_pkg', 'endpackage : shared_x87_reference_pkg')
    text = once(text, 'import fpu_x87_pkg::*;', 'import shared_fp_reference_pkg::*;')
    (output/'shared_x87_reference_pkg.sv').write_text(text)
    text = once(inputs[1].read_text(), 'module fpu_writeback\n',
                'module shared_fp_reference_writeback\n')
    text = once(text, 'import fpu_x87_pkg::*;', 'import shared_fp_reference_pkg::*;')
    text = once(text, 'import ventium_x87_pkg::*;', 'import shared_x87_reference_pkg::*;')
    prefix = '// Test-only sequential architectural reference; DUT flags are restored.\n'
    suffix = '\n'
    for macro in ('VEN_FP_PIPE', 'VEN_FP_PIPE2'):
        saved = 'ARCH_REFERENCE_RESTORE_'+macro
        prefix += f'`ifdef {saved}\n  `error "private oracle macro collision"\n`endif\n'
        prefix += f'`ifdef {macro}\n  `define {saved}\n  `undef {macro}\n`endif\n'
        suffix += f'`ifdef {saved}\n  `define {macro}\n  `undef {saved}\n`endif\n'
    (output/'shared_fp_reference_writeback.sv').write_text(prefix+text+suffix)
    text = once(inputs[2].read_text(), 'fpu_writeback u_old_wb (.*);',
                'shared_fp_reference_writeback u_old_wb (.*);')
    (output/'tb_ven_fp_arch_ab.sv').write_text(text)
    if not all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p, h in pins.items()):
        raise RuntimeError('reference source changed during preparation')
    (output/'inputs.json').write_text(json.dumps(pins, indent=2)+'\n')


if __name__ == '__main__':
    main()
