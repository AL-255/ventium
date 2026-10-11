#!/usr/bin/env python3
"""Prepare private read-ACK wiring and check source-extracted Boolean equivalence.

No cache-array, whole-core, timing, standard-suite or FPGA qualification.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from prepare_fp_read_ack_split import PARENTS, transform, ack_block, read_ack_block


def sha(p):
    with p.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--parent', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    parent = args.parent.resolve(strict=True)
    out = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    here = Path(__file__).resolve().parent
    assert __debug__ and out.is_relative_to(scratch) and not out.exists()
    assert Path(os.environ['TMPDIR']).resolve() == scratch
    assert shutil.disk_usage(scratch).free > 4*1024**3
    original = {name: (parent/name).read_text() for name in PARENTS}
    candidate = {name: transform(name, value) for name, value in original.items()}
    pins = {str(parent/name): digest for name, digest in PARENTS.items()}
    for p in (Path(__file__), here/'prepare_fp_read_ack_split.py',
              here/'test_fp_read_ack_split.py', here/'fp_read_ack_leaf.svh',
              Path('/usr/bin/iverilog').resolve(), Path('/usr/bin/vvp').resolve()):
        pins[str(p)] = sha(p)
    assert all(sha(Path(p)) == digest for p,digest in pins.items())
    out.mkdir()
    def save(name, value):
        with (out/name).open('x') as f: json.dump(value, f, indent=2)
    runs = []
    def run(label, argv, expected, marker=None, env=None):
        save(label+'.argv.json', list(map(str, argv)))
        with (out/(label+'.log')).open('x') as log:
            proc = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT,
                                  timeout=60, env=env)
        runs.append(dict(label=label, native_exit=proc.returncode,
                         log_sha256=sha(out/(label+'.log'))))
        assert proc.returncode == expected, runs[-1]
        if marker: assert marker in (out/(label+'.log')).read_text()
    began = time.monotonic()
    result = dict(passed=False, runs=runs, whole_core=False, timing_mhz=None,
                  gameplay_ipc=None, standard_suite=False, physical_board=False)
    try:
        run('recipe', ['python3','-B',here/'test_fp_read_ack_split.py'], 0,
            env={**os.environ, 'FP_READ_ACK_PARENT': str(parent)})
        for name, content in candidate.items():
            path = out/'candidate'/name
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('x') as f: f.write(content)
            pins[str(path)] = sha(path)
        name = 'rtl/mem/ven_l1d.sv'
        blocks = ack_block(original[name]) + '\n' + read_ack_block(candidate[name])
        body = (here/'fp_read_ack_leaf.svh').read_text()
        assert body.count('  // SOURCE_EXTRACTED_ACK_BLOCKS') == 1
        tb = out/'tb_fp_read_ack.sv'
        with tb.open('x') as f:
            f.write('module tb_fp_read_ack;\n' + body.replace('  // SOURCE_EXTRACTED_ACK_BLOCKS', blocks) + '\nendmodule\n')
        pins[str(tb)] = sha(tb)
        for profile, extra in (
            ('registered', []),
            ('registered-full', ['VEN_P54_DUAL_STORE_PAIR','VEN_L1D_CODE_WORD_REUSE','VEN_L1D_HIT_STREAM']),
            ('comb-dual', ['VEN_L1D_COMB_ACK','VEN_P54_DUAL_STORE_PAIR']),
            ('comb-stream', ['VEN_L1D_COMB_ACK','VEN_P54_DUAL_STORE_PAIR','VEN_L1D_HIT_STREAM']),
        ):
            binary = out/(profile+'.vvp')
            run(profile+'-build', ['/usr/bin/iverilog','-g2012','-s','tb_fp_read_ack',
                '-DVEN_FP_LOAD_EARLY_CMD',*['-D'+d for d in extra],'-o',binary,tb], 0)
            pins[str(binary)] = sha(binary)
            run(profile, ['/usr/bin/vvp',binary], 0,
                'FP-READ-ACK-OK samples=1048576 read_checked=524288')
            run(profile+'-negative', ['/usr/bin/vvp',binary,'+mutant_write'], 1, 'FP_READ_ACK_EQ')
        result['passed'] = True
    except Exception as error:
        import traceback
        result.update(error=repr(error), traceback=traceback.format_exc())
    result.update(seconds=time.monotonic()-began,
        pins_unchanged=all(sha(Path(p)) == digest for p,digest in pins.items()))
    result['passed'] &= result['pins_unchanged']
    save('pins.json', pins)
    save('closed.json', result)
    print(json.dumps(result), flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__': raise SystemExit(main())
