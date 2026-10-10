"""Source-extracted complete-beat ownership and payload mux equivalence.

The opcode whitelist is over-approximated by a free eligibility bit. All
complete-beat/permission/debug/fragment predicates are copied from actual RTL.
This checks payload ownership, not opcode decode, arithmetic or whole-core ISA.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

import prepare_fp_load_payload_select as recipe


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--core', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve() == scratch
    out = args.out.resolve()
    assert out.is_relative_to(scratch)
    out.mkdir()
    source = args.core.resolve(strict=True)
    fixture = Path(__file__).with_name('tb_fp_load_payload.sv')
    paths = (source, fixture, Path(__file__).resolve(), Path(recipe.__file__).resolve())
    pins = {str(p): sha(p) for p in paths}
    core = source.read_text()
    recipe.transform(core)  # Require the exact source/producer contracts.
    begin = '  assign fp_shared_load_cmd = cycle_mode && (state == S_FLOAD) &&'
    cut = '      ((q_fxop == FX_FLD_M32) || (q_fxop == FX_FLD_M64) ||'
    assert core.count(begin) == core.count(cut) == 1
    producer = core[core.index(begin):core.index(cut)]+'      op_eligible;\n'
    assert producer.rstrip().endswith('op_eligible;')
    take_begin = '  assign fp_load64_take = cycle_mode && (state == S_FLOAD) &&'
    start = core.index(take_begin)
    take = core[start:core.index(';', start)+1]
    take = '`ifdef VEN_FP_LOAD64\n'+take+'\n`else\n  assign fp_load64_take = 1\'b0;\n`endif\n'
    template = fixture.read_text()
    assert template.count('  // SOURCE_EXPRESSIONS') == 1
    rows = []
    errors = []
    started = time.monotonic()
    variants = [('narrow', False, None), ('wide', True, None),
                ('wrong-high-word', True, 'high'), ('wrong-low-word', True, 'low')]
    with (out/'started.json').open('x') as f:
        json.dump(dict(pins=pins, invocation=os.environ.get('INVOCATION_ID'),
            opcode_eligibility_overapproximated=True), f, indent=2)
    try:
        for name, wide, mutant in variants:
            leaf = out/name
            leaf.mkdir()
            new = recipe.NEW.replace('fp_shared_cmd_mem', 'new_mem')
            if mutant == 'high':
                assert new.count('bus_rdata_hi, mem_rdata') == 1
                new = new.replace('bus_rdata_hi, mem_rdata', 'f_mem80[63:32], mem_rdata')
            elif mutant == 'low':
                new = new.replace('mem_rdata, f_mem80[31:0]', 'f_mem80[31:0], mem_rdata')
            expressions = take+producer+recipe.OLD.replace('fp_shared_cmd_mem', 'old_mem')+'\n'+new
            sv = leaf/'tb.sv'
            sv.write_text(template.replace('  // SOURCE_EXPRESSIONS', expressions))
            command = ['iverilog', '-g2012', '-s', 'tb', '-o', str(leaf/'a.vvp'),
                *(['-DVEN_FP_LOAD64'] if wide else []), str(sv)]
            with (leaf/'build.log').open('x') as f:
                build = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT, timeout=20)
            assert build.returncode == 0, (name, 'build', build.returncode)
            with (leaf/'run.log').open('x') as f:
                run = subprocess.run(['vvp', str(leaf/'a.vvp')], stdout=f, stderr=subprocess.STDOUT, timeout=60)
            log = (leaf/'run.log').read_text()
            if mutant:
                assert run.returncode == 1 and 'PAYLOAD mismatch' in log, (name, run.returncode, log)
                counts = None
            else:
                assert run.returncode == 0, (name, run.returncode, log)
                matches = re.findall(r'^FP-LOAD-PAYLOAD-OK checks=(\d+) reads=(\d+) wide=(\d+)$', log, re.M)
                assert len(matches) == 1
                counts = list(map(int, matches[0]))
            rows.append(dict(name=name, native_build=build.returncode, native_run=run.returncode,
                required_negative=bool(mutant), counts=counts, source_sha256=sha(sv), binary_sha256=sha(leaf/'a.vvp')))
    except Exception as exc:
        errors.append(repr(exc))
    stable = all(sha(Path(p)) == h for p,h in pins.items())
    result = dict(passed=not errors and len(rows) == 4 and stable, rows=rows, errors=errors,
        pins_unchanged=stable, seconds=time.monotonic()-started,
        full_core=False, hardware_timing=False, gameplay_ipc=None, standard_suite=False)
    with (out/'closed.json').open('x') as f:
        json.dump(result, f, indent=2)
    print(json.dumps(result, indent=2), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
