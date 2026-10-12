"""Replay an existing cold fixture with read-only pairing observations.

Require every architectural/cycle record to match the original closed model.
This is diagnostic evidence, not a replacement for path-coverage acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from build_pair_now_observer import sha
sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'verif/diff'))
import tracefmt


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--observer', type=Path, required=True)
    ap.add_argument('--fixture', type=Path, required=True)
    ap.add_argument('--out', type=Path, required=True)
    args = ap.parse_args()
    observer = args.observer.resolve(strict=True); fixture = args.fixture.resolve(strict=True)
    root = Path('/home/yukidama/external/tmp').resolve(strict=True); out = args.out.resolve()
    assert Path(os.environ['TMPDIR']).resolve(strict=True) == root
    assert out.is_relative_to(root) and out != root and not out.exists()
    assert sorted(os.sched_getaffinity(0)) == [12]
    build = json.loads((observer/'closed.json').read_text())
    assert build['passed'] and build['pins_unchanged']
    pins = dict(build['pins']); binary = observer/'tb_pair_observer'
    assert sha(binary) == build['binary_sha256']
    for path in (Path(__file__).resolve(), binary, observer/'closed.json'):
        pins[str(path)] = sha(path)
    assert all(sha(p)==h for p,h in pins.items())
    out.mkdir(); rows = []
    result = dict(passed=False, pins=pins, rows=rows, invocation=os.environ.get('INVOCATION_ID'))
    env = {k:v for k,v in os.environ.items() if not k.startswith(('VEN_','VTM_','TB_','AXI_','QEMU_'))}
    try:
        for latency in (0,7):
            for mode in ('cycle','cycle-func'):
                name = f'candidate-lat{latency}-{mode}'
                commandfile = fixture/(name+'.command.json'); oldtrace = fixture/(name+'.vtrace')
                for path in (commandfile, oldtrace): pins[str(path)] = sha(path)
                command = json.loads(commandfile.read_text())
                models = [i for i,x in enumerate(command) if x.endswith('/obj/tb_ventium')]
                assert len(models)==1 and '--l1-axi' in command and '--'+mode in command
                assert sha(command[models[0]]) == build['model_sha256']
                command[models[0]] = str(binary)
                folder = out/name; folder.mkdir(); trace = folder/'rtl.vtrace'
                command[command.index('--out')+1] = str(trace)
                (folder/'command.json').write_text(json.dumps(command,indent=2)+'\n')
                with (folder/'stdout').open('x') as stdout, (folder/'stderr').open('x') as stderr:
                    native = subprocess.run(command, env=dict(env, AXI_RLAT=str(latency),
                        AXI_WLAT=str(latency), VENTIUM_PAIR_OBSERVE='1'),
                        stdout=stdout,stderr=stderr,timeout=50)
                assert native.returncode==133, native.returncode
                current, old = tracefmt.read_trace(str(trace)), tracefmt.read_trace(str(oldtrace))
                assert current.hdr == old.hdr and current.records == old.records
                count = sum(line.startswith('[PAIR-OBS]') for line in (folder/'stderr').read_text().splitlines())
                assert count, 'observer did not witness a pair request'
                rows.append(dict(latency=latency, mode=mode, records=len(current.records),
                    pair_request_edges=count, native_exit=native.returncode,
                    artifacts={str(p):sha(p) for p in folder.iterdir() if p.is_file()}))
        result['passed'] = True
    finally:
        result['pins_unchanged'] = all(sha(p)==h for p,h in pins.items())
        (out/'closed.json').write_text(json.dumps(result,indent=2)+'\n')
    assert result['pins_unchanged']
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}),flush=True)


if __name__ == '__main__': main()
