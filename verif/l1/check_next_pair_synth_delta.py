"""Preprocess the exact hardware profile: one request expression, no new state."""
import argparse
import difflib
import os
from pathlib import Path
import subprocess

from build_next_pair_cofactor_core import sha,load,save,stable


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for k in ('parent','candidate','out'): ap.add_argument('--'+k,type=Path,required=True)
    args = ap.parse_args(); root = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True) == scratch
    assert root.is_relative_to(scratch) and not root.exists()
    folders = {k:getattr(args,k).resolve(strict=True) for k in ('parent','candidate')}
    pins = {str(Path(__file__).resolve()):sha(__file__)}; prepared = {}
    for k,folder in folders.items():
        prepared[k] = load(folder/'prepared.json'); pins.update(prepared[k]['pins'])
        assert load(folder/'build-closed.json')['passed']
    assert prepared['parent']['definitions'] == prepared['candidate']['definitions']
    assert stable(pins)
    root.mkdir(); outputs = {}
    for k,folder in folders.items():
        core = folder/'candidate/rtl/core'
        command = ['/tools/verilator/v5.046/bin/verilator','-E','-P','+define+SYNTHESIS',
                   *['+define+'+d for d in prepared[k]['definitions']],
                   '-I'+str(core),str(core/'core_mem_chain.svh')]
        with (root/(k+'.sv')).open('x') as out,(root/(k+'.stderr')).open('x') as err:
            p = subprocess.run(command,stdout=out,stderr=err,timeout=30)
        assert p.returncode == 0,(k,p.returncode)
        # -E retains comments and blank lines; neither is hardware behavior.
        text = (root/(k+'.sv')).read_text()
        outputs[k] = [line.split('//',1)[0].strip() for line in text.splitlines()
                      if line.split('//',1)[0].strip()]
        assert not any(token in text for token in ('NEXT-PAIR-PROBE','np_clocks','NEXT-PAIR-COFACTOR:'))
        for f in (root/(k+'.sv'),root/(k+'.stderr')): pins[str(f)] = sha(f)
    before = outputs['parent']; after = outputs['candidate']
    old = 'assign mem_next_req = agi_prime_offer || ref_prime_offer || mc_offer || mc_prime_offer;'
    assert before.count(old) == 1
    at = before.index(old)
    expected = before[:at]+[
        'assign mem_next_req = (agi_prime_offer || ref_prime_offer || mc_offer || mc_prime_offer) &&',
        '!(pipe_load_req && pipe_store_pair_shape);']+before[at+1:]
    assert after == expected, '\n'.join(difflib.unified_diff(expected,after))
    assert stable(pins)
    save(root/'closed.json',dict(passed=True,pins=pins,pins_unchanged=True,
        native_preprocesses=2,hardware_delta='one combinational request expression',
        added_hardware_state=False,added_hardware_ports=False,synthesis_completed=False,
        fmax_mhz=None,hardware_acceptance=False,gameplay_ipc=None))
    print('NEXT-PAIR-SYNTH-DELTA-OK: exactly one combinational request expression',flush=True)


if __name__ == '__main__': main()
