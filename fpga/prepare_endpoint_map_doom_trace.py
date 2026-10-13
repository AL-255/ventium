"""Derive a shorter passive cold Doom diagnostic from the closed smoke runner.

No new model, guest patch, debugger breakpoint, STEP, save or restore. Keep
the exact smoke-run resource/lifecycle checks, add bounded existing observers.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

PARENT = '2a58fc38f7a1f96539a0cbf731016cea6fe9592f8e2f40cbd5de7fb53a9991e9'


def change(text, old, new, count=1):
    if text.count(old) != count:
        raise ValueError('Doom trace source drift: '+old)
    return text.replace(old,new)


def transform(text):
    if hashlib.sha256(text.encode()).hexdigest() != PARENT:
        raise ValueError('Doom smoke runner drift')
    text = change(text,'100000000','34000000',2)
    text = change(text,'1800','900',2)
    text = change(text,"'--fb-every','10000000','--fb-out',str(out/'frame')]",
        "'--fb-every','10000000','--fb-out',str(out/'frame'),\n"
        "        '--vtm-dump-start','4098000','--vtm-dump','40000',\n"
        "        '--ven-state-start','32720000','--ven-state-cycles','20000',\n"
        "        '--ven-state-fetch','--ven-fault-ring',str(out/'fault-ring.log'),\n"
        "        '--ven-fault-ring-start','4000000','--ven-fault-ring-events','8']")
    text = change(text,'diagnostic_only=True,\n        standard_suite=False',
        'diagnostic_only=True,passive_cold_trace=True,\n        standard_suite=False')
    text = change(text,"graphics_captures=len(re.findall(r'^\\[FBCAP\\]',text,re.M)))",
        "stall_observed=bool(re.search(r'^\\[STALL\\] no retire',text,re.M)),\n"
        "        graphics_captures=len(re.findall(r'^\\[FBCAP\\]',text,re.M)))")
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    args = ap.parse_args()
    out = args.out.resolve()
    scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert __debug__ and out.is_relative_to(scratch) and out != scratch and not out.exists()
    assert shutil.disk_usage(scratch).free > 5*1024**3
    source = Path(__file__).with_name('run_endpoint_map_doom_smoke.py')
    text = transform(source.read_text())
    out.mkdir()
    (out/'run.py').write_text(text)
    with (out/'prepared.json').open('x') as f:
        json.dump(dict(parent_path=str(source),parent_sha256=PARENT,
            driver_sha256=hashlib.sha256(text.encode()).hexdigest(),
            max_cycles=34000000,max_seconds=900,retire_window=[4098000,4138000],
            state_window=[32720000,32740000],fault_events=8,
            cold=True,passive=True,new_model=False,guest_modified=False),f,indent=2)


if __name__ == '__main__': main()
