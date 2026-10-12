"""Additional memory-divide corpus; original FP/canonical gates stay unchanged.

Reuse their complete QEMU/native grading for a NEW eight-form fixture. Compare
all A/B architectural fields too. Every image has exactly 16 memory divides;
allow at most 16 additional total clocks, not unrestricted timing regression.
The separate original FP corpus must still retain exact cycle equivalence.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(REPO/'verif/l1'))
import run_load_read_ack_core as prior


def adapt(original):
    text=prior.adapt(original,'fp')
    def replace(old,new):
        nonlocal text
        if text.count(old)!=1: raise ValueError('memory-divide corpus anchor: '+old)
        text=text.replace(old,new)
    replace('else range(6)', 'else range(8)')
    replace('0 <= x < 6 for x in kinds', '0 <= x < 8 for x in kinds')
    replace("'fp-payload-system.S'", "'memdiv-capture-system.S'")
    replace('''        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
''', '        port = 26000 + 64 * kind + 32 * reloc + offset\n')
    replace('        cycle_observations = {}',
            '        cycle_observations = {}\n        architectural_observations = {}')
    replace('                rows = traces[\'cycle\']',
            "                architectural_observations[latency,name] = traces['cycle-func']\n"
            "                rows = traces['cycle']")
    replace("            assert accept_observations[(latency,'control')] == accept_observations[(latency,'candidate')], 'FP acceptance events differ'",
            """            old_accept = accept_observations[latency,'control']
            new_accept = accept_observations[latency,'candidate']
            assert [r[1:] for r in old_accept] == [r[1:] for r in new_accept], 'FP owner sequence differs'
            assert architectural_observations[latency,'control'] == architectural_observations[latency,'candidate'], 'complete architectural state differs'""")
    replace("            assert cycle_observations[(latency,'control')] == cycle_observations[(latency,'candidate')], 'entire cycle record lists differ'",
            """            old_cycles = cycle_observations[latency,'control']
            new_cycles = cycle_observations[latency,'candidate']
            assert [(r['n'],r['pc']) for r in old_cycles] == [(r['n'],r['pc']) for r in new_cycles]
            assert sum(int(r['pc'],0)==symbols['hot_div'] for r in new_cycles)==16
            for old_row,new_row in zip(old_cycles,new_cycles):
                assert 0 <= new_row['cyc']-old_row['cyc'] <= 16, (case,latency,'stage latency budget',old_row,new_row)""")
    replace('complete_cycle_streams_identical=True',
            'complete_architectural_streams_identical=True, max_added_clocks=16')
    replace("        assert all(r['saved_clocks']==0 for r in deltas)",
            "        assert all(-16 <= r['saved_clocks'] <= 0 for r in deltas)")
    replace("        assert all(r['saved_clocks']>=0 for r in deltas)",
            "        assert all(-16 <= r['saved_clocks'] <= 0 for r in deltas)")
    return text


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    args,extra=ap.parse_known_args(); root=args.out.resolve()
    scratch=Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve()==scratch
    assert root.is_relative_to(scratch) and root!=scratch and not root.exists()
    assert shutil.disk_usage(scratch).free>4.5*1024**3
    assert '--operand-offset' not in extra
    lo,hi=map(int,Path('/proc/sys/net/ipv4/ip_local_port_range').read_text().split())
    assert 26511<lo or 26000>hi
    source=REPO/'verif/issue_uv/run-fp-high-payload-ab.py'
    runner=root.with_suffix('.driver.py')
    with runner.open('x') as stream: stream.write(adapt(source.read_text()))
    pins={str(p):prior.corpus.base.sha(p) for p in (Path(__file__),Path(prior.__file__),
        Path(prior.corpus.__file__),Path(prior.corpus.base.__file__),source,runner,
        REPO/'verif/issue_uv/memdiv-capture-system.S')}
    command=[sys.executable,'-B',str(runner),'--out',str(root),*extra]
    with root.with_suffix('.driver.json').open('x') as stream:
        json.dump(dict(pins=pins,command=command,new_fixture=True,
            original_gates_unchanged=True,complete_architectural_comparison=True,
            allowed_added_clocks_per_16_divides=16,gameplay_ipc=None),stream,indent=2)
    with root.with_suffix('.driver.log').open('x') as stream:
        result=subprocess.run(command,stdout=stream,stderr=subprocess.STDOUT,timeout=300)
    assert all(prior.corpus.base.sha(p)==h for p,h in pins.items())
    return result.returncode


if __name__=='__main__': raise SystemExit(main())
