#!/usr/bin/env python3
"""Four bounded platform-cache leaf builds, then 32 independent native tests."""
from concurrent.futures import ThreadPoolExecutor
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

from prepare_l2_capacity import transform, repair_lru_lookup

REPO = Path(__file__).resolve().parents[2]


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def tie_unused_primitive_inputs(text, primitives):
    # The historical leaf omits eight optional altdpram pins. The frozen
    # behavioral primitive never reads them. Bind documented inactive/enabled
    # values in BOTH variants rather than suppressing PINMISSING.
    primitive = primitives.split('module altdpram #(',1)[1].split('endmodule',1)[0]
    values = dict(aclr=0,byteena=1,inclocken=1,outclocken=1,rdaddressstall=0,rden=1,sclr=0,wraddressstall=0)
    for pin in values:
        assert len(re.findall(r'\b'+pin+r'\b',primitive)) == 1, 'primitive now consumes '+pin
    before = '.outclock(CLK),'
    assert text.count(before) == 3
    after = before+'\n'+''.join(f"\t.{pin}(1'b{value}),\n" for pin,value in values.items())
    return text.replace(before,after)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--prims', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--repair-lru', action='store_true', help='prime actual request LRU set at admission')
    ap.add_argument('--unsafe-read-only', action='store_true', help='negative control: omit registered write owner')
    ap.add_argument('--unsafe-no-forward', action='store_true', help='negative control: omit pending-rank forwarding')
    ap.add_argument('--check-lru-owner', action='store_true', help='assert set ownership before victim selection')
    ap.add_argument('--check-lru-write-owner', action='store_true')
    ap.add_argument('--words', type=int, nargs='+', default=[8])
    ap.add_argument('--gaps', type=int, nargs='+', default=[1])
    ap.add_argument('--stream', choices=('any','lower','legacy'), default='any')
    ap.add_argument('--xpm-fidelity', action='store_true', help='FPGA registered-output/read-first data RAM model')
    ap.add_argument('--sets', type=int, nargs='+', default=[128,256,512,1024])
    args = ap.parse_args()
    assert not args.unsafe_read_only or args.repair_lru
    assert set(args.words) <= set(range(1,9)) and set(args.gaps) <= {0,1}
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    out = args.out.resolve()
    assert out.is_relative_to(scratch) and shutil.disk_usage(scratch).free > 2*1024**3
    out.mkdir()
    paths = [args.source.resolve(strict=True), args.prims.resolve(strict=True),
             REPO/'verif/l1/tb_l2_capacity.sv', Path(__file__).resolve(),
             REPO/'verif/l1/prepare_l2_capacity.py']
    pins = {str(p):sha(p) for p in paths}
    (out/'scripts').mkdir()
    for source in paths[3:]: shutil.copyfile(source,out/'scripts'/source.name)
    frozen_scripts = {str(p):sha(p) for p in (out/'scripts').iterdir()}
    for name, source in [('control.v',paths[0]),('prims.sv',paths[1]),('tb_l2_capacity.sv',paths[2])]:
        shutil.copyfile(source,out/name)
    control = tie_unused_primitive_inputs(paths[0].read_text(),paths[1].read_text())
    if args.repair_lru:
        control = repair_lru_lookup(control, write_owner=not args.unsafe_read_only,
                                    forward=not args.unsafe_no_forward)
    (out/'control.v').write_text(control)
    (out/'candidate.v').write_text(transform(control))
    (out/'started.json').write_text(json.dumps(dict(pins=pins,started=time.time()),indent=2))
    commands = []
    rows = []
    # Preserve the existing serialized-scope lock across Python subprocesses.
    # An environment marker alone is deliberately rejected by the wrapper.
    lock_fds = tuple(int(p.name) for p in Path('/proc/self/fd').iterdir()
                     if p.name.isdigit() and p.exists() and
                     p.resolve() == Path('/tmp/ventium-heavy-build.lock'))
    assert lock_fds, 'launch under tools/build_scope.sh, not an unbounded process'
    def command(argv, name, limit=180):
        commands.append([str(v) for v in argv])
        with (out/(name+'.log')).open('xb') as log:
            done = subprocess.run(argv,cwd=REPO,stdout=log,stderr=subprocess.STDOUT,
                                  timeout=limit,pass_fds=lock_fds)
        assert done.returncode == 0, (name,done.returncode)
        return (out/(name+'.log')).read_text()
    error = None
    try:
        assert set(args.sets) <= {128,256,512,1024} and len(set(args.sets)) == len(args.sets)
        for sets in args.sets:
            argv = [str(REPO/'tools/verilator_serial.sh'),'--binary','--timing','--assert',
                '-j','32','--output-split','10000','--output-split-cfuncs','200',
                '-sv','-Wall','-Wno-UNUSED','-Wno-fatal',
                *['-Werror-'+k for k in ('IMPLICIT','PINMISSING','UNDRIVEN','MULTIDRIVEN','LATCH','UNOPTFLAT')],
                '-DVEN_L2_PERF',
                '--top-module','tb_l2_capacity',f'-GSETS={sets}',
                '--Mdir',str(out/f'obj{sets}'),'-o','test',str(out/'tb_l2_capacity.sv'),
                str(out/('control.v' if sets==128 else 'candidate.v')),str(out/'prims.sv')]
            if args.stream != 'legacy': argv.insert(1,'-DVEN_L2_STREAM_CWF')
            if args.stream == 'any': argv.insert(1,'-DVEN_L2_STREAM_ANY')
            if args.xpm_fidelity: argv.insert(1,'-DVEN_ALTSYNCRAM_XPM')
            if sets != 128:
                argv.insert(1,'-DL2_CAPACITY_PARAM')
            if args.check_lru_owner:
                argv.insert(1,'-DCHECK_LRU_OWNER')
            if args.check_lru_write_owner:
                argv.insert(1,'-DCHECK_LRU_WRITE_OWNER')
            if args.repair_lru and not args.unsafe_read_only:
                argv.insert(1,'-DLRU_SEPARATE_WRITE_OWNER')
            command(argv,f'build{sets}')
        jobs = [(sets,lines,seed,words,gap) for sets in args.sets
                for lines in (512,1024,2048,4096) for seed in (1,2)
                for words in args.words for gap in args.gaps]
        def run(job):
            sets,lines,seed,words,gap = job
            text = command([str(out/f'obj{sets}/test'),f'+LINES={lines}',f'+SEED={seed}',
                            f'+WORDS={words}',f'+GAP={gap}'],
                           f'run-{sets}-{lines}-{seed}-{words}-{gap}',60)
            match = re.search(r'L2-CAPACITY-OK sets=(\d+) lines=(\d+) seed=(\d+) '
                              r'warm_misses=(\d+) warm_clocks=(\d+) mutations=(\d+)',text)
            assert match and list(map(int,match.groups()[:3])) == [sets,lines,seed]
            return dict(zip(('sets','lines','seed','warm_misses','warm_clocks','mutations'),map(int,match.groups())),
                        words=words,gap=gap)
        with ThreadPoolExecutor(max_workers=32) as pool:
            rows = list(pool.map(run,jobs))
    except Exception as exc:
        error = repr(exc)
    stable = all(sha(p)==h for p,h in pins.items())
    result = dict(passed=error is None and stable, error=error, stable_inputs=stable,
                  source_pins=pins, commands=commands, rows=rows, finished=time.time(),
                  frozen_script_pins=frozen_scripts,
                  core_l1_unchanged=True, gameplay_ipc=None, production_selected=False,
                  lru_repaired=args.repair_lru, lru_owner_assertions=args.check_lru_owner,
                  unsafe_read_only=args.unsafe_read_only,
                  unsafe_no_forward=args.unsafe_no_forward,
                  stream_profile=args.stream,
                  xpm_fidelity=args.xpm_fidelity,
                  lru_write_owner_assertions=args.check_lru_write_owner,
                  full_system_acceptance=False, physical_qualified=False)
    (out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(passed=result['passed'],error=error,cases=len(rows),evidence=str(out))),flush=True)
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
