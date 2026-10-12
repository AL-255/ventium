"""Transfer the immediate paired-read completion cut into the exact PC parent.

Admit only closed source-matched directed tests and an actual immediate-return
witness. Canonical failure remains explicit; this is not workload acceptance.
"""
import argparse
import os
from pathlib import Path
import shutil

import build_memdiv_query_soc as base
import prepare_pair_now_read_ack as recipe

sha, load, stable = base.sha, base.load, base.stable
PARENT_MODEL = 'eebeb872631af564d340958bfe0c3576ab7ac9c56fb18b7f57af2b2a9ea50987'
CORE_MODEL = '66cfd2e6365d0093d395e807e07bcd5148ae76a3701e64d5d1a58ae18e800750'
BASE_SHA = 'e8eef6ff4134e714e466f811b4a0185836443b0a532b6c7d1c1a42d365f5db5b'


def regressions(core):
    root, pins, statistics = core.parent, {}, {}
    model = str(core/'obj/tb_ventium')
    for label, count in (('fp',1536), ('memory',288), ('branch',2560), ('faults',32),
                         ('sameline',192), ('warm',192)):
        folder = root/('pair-now-read-'+label+'-r1')
        if label == 'warm': folder /= 'matrix'
        before, done = load(folder/'started.json'), load(folder/'closed.json')
        assert done['passed'] and done['pins_unchanged'] and not done['errors']
        assert before['models']['candidate'] == model and stable(before['pins'])
        assert len(done['measurements']) == count
        rows = [r for r in done['measurements'] if r['model']=='candidate']
        assert len(rows) == count//2
        if label == 'faults':
            assert all(not r[k]['timed_out'] and r[k]['native_exit']==0
                       for r in done['measurements'] for k in ('gate','complete_uv_compare'))
            assert all(sha(folder/p)==h for p,h in done['artifacts'].items())
        elif label == 'fp':
            assert len(done['deltas']) == count//2
            assert all(r['saved_clocks']==0 for r in done['deltas'])
        else:
            assert sum(r.get('paired_v',r.get('memory_v',0)) for r in rows)>0
        statistics[label] = dict(records=sum(r['records'] for r in rows),measurements=count)
        pins.update(before['pins'])
        for p in (folder/'started.json',folder/'closed.json'): pins[str(p)]=sha(p)
        if label in ('sameline','warm'):
            adapter = folder.parent/'adapter.json' if label=='warm' else folder/'adapter.json'
            checked = load(adapter)
            assert checked['pins_unchanged'] and checked['native_runner_exit']==0
            assert checked['result_sha256']==sha(folder/'closed.json') and stable(checked['pins'])
            pins.update(checked['pins']); pins[str(adapter)]=sha(adapter)
    folder = root/'pair-now-read-held-r1'
    done, inputs = load(folder/'result.json'), load(folder/'inputs.json')
    assert done['passed'] and done['inputs_unchanged'] and not done['errors']
    assert len(done['cases'])==48 and model in inputs and stable(inputs)
    assert all(r['measurements']['control']==r['measurements']['candidate'] for r in done['cases'])
    statistics['held'] = dict(records=sum(r['measurements']['candidate']['records'] for r in done['cases']))
    pins.update(inputs)
    for p in (folder/'result.json',folder/'inputs.json'): pins[str(p)]=sha(p)
    folder = root/'pair-now-read-replay-r1'
    before, done = load(folder/'started.json'), load(folder/'closed.json')
    assert done['same_input_regression_passed'] and done['pins_unchanged'] and not done['errors']
    assert len(done['rows'])==108 and done['records']==80800 and stable(before['pins'])
    assert before['models']['candidate']==model
    pins.update(before['pins'])
    for p in (folder/'started.json',folder/'closed.json'): pins[str(p)]=sha(p)
    witness = root/'pair-now-read-witness-warm-r1/closed.json'
    done = load(witness)
    assert done['passed'] and done['pins_unchanged'] and stable(done['pins'])
    assert len(done['rows'])==16
    assert {r['label'] for r in done['rows']}=={'wide','byte','same-bank','split'}
    for row in done['rows']:
        assert row['native_exit']==133 and stable(row['artifacts'])
        if row['label'] in ('wide','byte'): assert row['immediate_hot_pairs']>=12
        else: assert row['immediate_hot_pairs']==0
        pins.update(row['artifacts'])
    statistics['immediate_witness'] = dict(runs=16,events=sum(r['immediate_hot_pairs'] for r in done['rows']))
    pins.update(done['pins']); pins[str(witness)]=sha(witness)
    archive = root/'closed-pair-now-fp-text'
    packed = load(Path(str(archive)+'-closed.json'))
    assert packed['completed'] and packed['all_members_byte_verified'] and packed['protected_pins_unchanged']
    assert sum(r['candidate_records'] for r in packed['statistics'])==208128
    assert sha(Path(str(archive)+'.tar.gz'))==packed['archive_sha256']
    for suffix in ('-closed.json','-plan.json','.tar.gz'):
        p=Path(str(archive)+suffix); pins[str(p)]=sha(p)
    # Include this adapter itself as well as the reused preparation/builder.
    for p in (Path(__file__).resolve(),Path(base.__file__),Path(recipe.__file__)):
        pins[str(p)]=sha(p)
    return pins, statistics


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('action',choices=('prepare','build'))
    for name in ('parent','core'): ap.add_argument('--'+name,type=Path)
    ap.add_argument('--out',type=Path,required=True)
    args = ap.parse_args()
    root = Path('/home/yukidama/external/tmp').resolve(strict=True); out=args.out.resolve()
    assert __debug__ and Path(os.environ['TMPDIR']).resolve(strict=True)==root
    assert out.is_relative_to(root) and out!=root and root.stat().st_dev!=base.REPO.stat().st_dev
    assert shutil.disk_usage(root).free>5*1024**3
    assert sha(base.__file__)==BASE_SHA
    base.PARENT_MODEL=PARENT_MODEL; base.CORE_MODEL=CORE_MODEL
    base.recipe=recipe; base.regressions=regressions
    if args.action=='prepare':
        base.prepare(args.parent.resolve(strict=True),args.core.resolve(strict=True),out)
        print('Prepared immediate paired-read PC; compiler not launched.',flush=True)
    else:
        return base.base.build(out)
    return 0


if __name__=='__main__': raise SystemExit(main())
