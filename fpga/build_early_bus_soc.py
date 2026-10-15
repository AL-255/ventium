"""Transfer the early address default into the source-matched full PC.

One HDL file changes; all 157 defines, strict #MF, FPREM repairs, full P5 L1s,
posted-16 transport and single-fill are inherited unchanged. Not acceptance.
"""
import inspect
from pathlib import Path
import sys

import build_decode_bus_soc as predecessor

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(REPO/'verif/fetchguard'))
import prepare_early_bus_payload as recipe

PARENT_MODEL = '7e877b3b9e43c2867fa3adcd93419c9b9f5fbca30b1a1ef9acacada04539ec68'
CORE_MODEL = 'c55b996c2c8309e2c152dbab2813a144e5e30db83df6acfa190425e94067b84f'
CHANGES = [recipe.FILE]
sha,load,save,stable,base = predecessor.sha,predecessor.load,predecessor.save,predecessor.stable,predecessor.base
FLAG = predecessor.FLAG


def keep_definitions(command):
    defs=[s[2:] for s in command if s.startswith('-D')]+[s[8:] for s in command if s.startswith('+define+')]
    assert len(defs)==len(set(defs))==157 and FLAG in defs
    return list(command),defs


def prepare(parent,core,proof,root):
    namespace=dict(predecessor.__dict__)
    namespace.update(__file__=__file__,PARENT_MODEL=PARENT_MODEL,CORE_MODEL=CORE_MODEL,
                     recipe=recipe,CHANGES=CHANGES,add_strict=keep_definitions,predecessor=predecessor)
    text=inspect.getsource(predecessor.prepare)
    changes=[("('decode-bus-boundary-r1', 'decode-bus-system-r1', 'decode-bus-func-r1', 'decode-bus-delivery-r1')",
              "('early-bus-boundary-r1', 'early-bus-system-r1', 'early-bus-func-r2', 'early-bus-delivery-r2', 'early-bus-physical-r2')"),
             ("name.endswith('delivery-r1')","name.endswith('delivery-r2')"),
             ("name.endswith('func-r1')","name.endswith('func-r2')"),
             ("set(defs)-{FLAG}","set(defs)"),
             ("'sim_decode_bus_'","'sim_early_bus_'"),
             ("added_defines=[FLAG]","added_defines=[]"),
             ("Path(__file__),\n", "Path(__file__),Path(predecessor.__file__),\n"),
             ("included_fixes=['strict waiting-x87 #MF', 'DECODE no-beat bus payload']",
              "included_fixes=['early linear payload default; original bus driver assertions']")]
    original=text
    for old,new in changes:
        assert text.count(old)==1,old
        text=text.replace(old,new)
    recovered=text
    for old,new in reversed(changes): recovered=recovered.replace(new,old)
    assert recovered==original
    # Broader payload changes also require the real INT/IRET and SMM witnesses.
    physical=load(proof/'early-bus-physical-r2/closed.json')
    assert physical['passed'] and physical['pins_unchanged'] and not physical['errors']
    assert len(physical['rows'])==18 and all(r['paired_v']>0 for r in physical['rows'])
    marker='    pins, statistics = {}, {}\n'
    assert text.count(marker)==1
    text=text.replace(marker,marker+'''    matched=load(proof/'early-bus-matched-inputs-r1/closed.json')
    inputs=load(proof/'early-bus-matched-inputs-r1/started.json')
    assert matched['regression_check_passed'] and matched['pins_unchanged'] and not matched['errors']
    assert len(matched['rows'])==108 and not matched['masks_or_record_normalization']
    assert stable(inputs['pins'])
    pins.update(inputs['pins'])
    for p in (proof/'early-bus-matched-inputs-r1/started.json',proof/'early-bus-matched-inputs-r1/closed.json'):
        pins[str(p)]=sha(p)
''')
    exec(compile(text,__file__,'exec'),namespace)
    return namespace['prepare'](parent,core,proof,root)


def main():
    namespace=dict(predecessor.__dict__)
    namespace.update(__file__=__file__,prepare=prepare)
    text=inspect.getsource(predecessor.main)
    text=text.replace('Prepared one HDL delta plus strict-MF define; no compiler launched.',
                      'Prepared one HDL delta, unchanged strict-MF profile; no compiler launched.')
    exec(compile(text,__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__': raise SystemExit(main())
