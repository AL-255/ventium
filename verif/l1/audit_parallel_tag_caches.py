#!/usr/bin/env python3
"""Reopen whole-cache/pair native results before a parallel-tag core build."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile
from run_parallel_tag_cache import sha, miter_fixture
from run_parallel_tag_pairs import fixture
from prepare_parallel_tag_lookup import PARENT, transform


def load(path):
    return json.loads(path.read_text())


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--root', type=Path, required=True)
    args = ap.parse_args()
    root = args.root.resolve(strict=True)
    repo = Path(__file__).resolve().parents[2]
    assert __debug__ and root.is_relative_to(Path('/home/yukidama/external/tmp').resolve(strict=True))
    leaf = load(root/'audit.json')
    assert leaf['passed'] and leaf['samples'] == 262144
    pins = dict(leaf['pins'])
    summary, owners = {}, []
    old = (root/'cache-r1/control_l1d.sv').read_text().replace('module control_l1d #(', 'module ven_l1d #(', 1)
    assert hashlib.sha256(old.encode()).hexdigest() == PARENT
    candidate = (root/'cache-r1/ven_l1d.sv').read_text()
    assert candidate == transform(old)
    wrong = candidate
    for bit in (0,1):
        a = f'mc_lookup_next ? tag_prime_hit[{bit}] : tag_current_hit[{bit}]'
        assert wrong.count(a) == 1
        wrong = wrong.replace(a, f'mc_lookup_next ? tag_current_hit[{bit}] : tag_prime_hit[{bit}]')
    assert (root/'cache-r1/wrong_select.sv').read_text() == wrong
    for kind in ('cache', 'pairs'):
        folder = root/(kind+'-r1')
        closed = load(folder/'closed.json')
        queue = load(root/(kind+'-queue-closed.json'))
        assert closed['passed'] and closed['pins_unchanged'] and not closed['error']
        assert queue['passed'] and queue['pins_unchanged']
        assert queue['native_receipt_sha256'] == sha(folder/'closed.json')
        pins.update(closed['pins'])
        unit = f'ventium-parallel-tags-{kind}-oct11.service'
        props = dict(s.split('=',1) for s in subprocess.check_output(['systemctl','--user','show',unit,
            '-pInvocationID','-pSubState','-pMainPID','-pExecMainStatus'],text=True).splitlines())
        assert props == queue['native_owner']
        assert props['SubState'] == 'exited' and props['MainPID'] == '0' and props['ExecMainStatus'] == '0'
        owners.append(dict(unit=unit, **props))
        config = subprocess.check_output(['systemctl','--user','cat',unit],text=True)
        assert f'run_parallel_tag_{kind}.py' in config and root.name in config
        assert 'VENTIUM_BUILD_SCOPE_PROFILE=ipc_parallel32' in config
        expected = {f'positive-{p}-lut{f}' for f in (0,1) for p in ('chain','reset_drop','reset_keep')} | {f'wrong-chain-lut{f}' for f in (0,1)} if kind == 'cache' else {f'positive-lut{f}-keep{k}' for f in (0,1) for k in (0,1)} | {f'wrong-lut{f}-keep0' for f in (0,1)}
        assert {r['label'] for r in closed['rows']} == expected
        assert len(closed['rows']) == len(expected)
        counts = dict(positive=0, defects=0, cycle_samples=0, pair_samples=0, next_samples=0)
        for row in closed['rows']:
            path = folder/row['label']
            pair = kind == 'pairs'
            stream = not pair and row['profile'] != 'chain'
            top = 'tb_l1d_' + ('pair_store' if pair else 'window_keep_reset' if stream else 'mem_chain')
            original = repo/'verif/l1'/(top+'.sv')
            generated = path/(top+'.sv')
            expect_tb = fixture(original.read_text(),row['flat']) if pair else miter_fixture(original.read_text(),stream,row['flat'])
            assert generated.read_text() == expect_tb
            command = load(path/'command.json')
            assert command[0] == str(repo/'tools/verilator_serial.sh')
            assert command[command.index('-j')+1] == '32' and '--assert' in command
            assert command[command.index('--top-module')+1] == top
            assert command[command.index('--Mdir')+1] == str(path/'obj')
            assert set(re.findall(r'\+define\+(\w+)', ' '.join(command))) == set(row['defines'])
            assert ('VEN_L1D_TAG_LUTRAM' in row['defines']) == row['flat']
            assert {'VEN_PIPE_MEM_CHAIN','VEN_L1D_BANKED_DATA'} <= set(row['defines'])
            assert command[-3:] == [str(root/'cache-r1/control_l1d.sv'),
                str(root/'cache-r1'/('wrong_select.sv' if row['mutant'] else 'ven_l1d.sv')), str(generated)]
            assert row['build_exit'] == 0
            binary = path/'obj'/('V'+top)
            assert sha(binary) == row['binary_sha256']
            for phase in ('build','run'):
                assert sha(path/(phase+'.log')) == row[phase+'_log_sha256']
            log = (path/'run.log').read_text()
            if row['mutant']:
                assert row['native_exit'] != 0 and ('PARALLEL-PAIR-MISMATCH' if pair else 'PARALLEL-CACHE-MISMATCH') in log
                counts['defects'] += 1
            else:
                assert row['native_exit'] == 0 and not re.search(r'FAIL|%Error|%Fatal|MISMATCH',log)
                marker = 'L1D-PAIR-STORE-GATE-OK' if pair else 'L1D-WINDOW-KEEP-RESET-OK' if stream else 'L1D-MEM-CHAIN-OK accepted=150 '
                assert marker in log
                expression = r'^PARALLEL-PAIR-MITER checks=(\d+) pairs=(\d+) rejected_store_hints=(\d+)$' if pair else r'^PARALLEL-CACHE-MITER checks=(\d+) next=(\d+)$'
                n = re.findall(expression,log,re.M)
                assert len(n) == 1 and int(n[0][0]) == row['cycle_samples'] >= 100
                if pair:
                    assert int(n[0][1]) == row['pair_samples'] > 10
                    assert int(n[0][2]) == row['rejected_store_hints'] > 20
                    assert '[load/store] registered U hit' in log and '[pair] snoop rejects' in log
                    counts['pair_samples'] += row['pair_samples']
                else:
                    assert int(n[0][1]) == row['next_samples']
                    assert stream or row['next_samples'] > 0
                    counts['next_samples'] += row['next_samples']
                counts['positive'] += 1
                counts['cycle_samples'] += row['cycle_samples']
            archive = row['compiler_archive']
            assert sha(archive['path']) == archive['sha256']
            # Stream archive members, avoiding re-expansion onto the full disk.
            proc = subprocess.Popen(['zstd','-dc',archive['path']],stdout=subprocess.PIPE)
            observed = []
            with tarfile.open(fileobj=proc.stdout,mode='r|') as tar:
                for member in tar:
                    assert member.isfile()
                    with tar.extractfile(member) as data:
                        observed.append(dict(path=member.name,bytes=member.size,sha256=hashlib.file_digest(data,'sha256').hexdigest()))
            assert proc.wait(timeout=30) == 0 and observed == archive['objects']
            for p in (generated,path/'command.json',path/'build.log',path/'run.log',binary,Path(archive['path']),path/'closed.json'):
                pins[str(p)] = sha(p)
        summary[kind] = counts
        for p in (folder/'closed.json',root/(kind+'-queue-closed.json'),root/(kind+'-launch-command.json')):
            pins[str(p)] = sha(p)
    for p in (Path(__file__),root/'audit.json',repo/'verif/l1/run_parallel_tag_pairs.py',
              repo/'verif/l1/run_parallel_tag_cache.py',repo/'verif/l1/prepare_parallel_tag_lookup.py'):
        pins[str(p)] = sha(p)
    assert all(sha(p)==h for p,h in pins.items())
    result = dict(passed=True,pins=pins,owners=owners,summary=summary,whole_cache=True,
                  whole_core=False,standard_suite=False,hardware_acceptance=False,gameplay_ipc=None,timing_mhz=None)
    with (root/'cache-audit.json').open('x') as f:
        json.dump(result,f,indent=2)
    print(json.dumps({k:v for k,v in result.items() if k!='pins'}))


if __name__ == '__main__':
    main()
