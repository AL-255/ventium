"""Unchanged cold input and short CoreMark controls for the system ACK cut."""
import argparse
from pathlib import Path
import sys
from types import SimpleNamespace

import build_system_read_ack_soc as build
import raw_prime_storage_controls as previous_controls

TEMPLATES=previous_controls.TEMPLATES
ADAPTER_SHA='3c882ba9c03705446bed04f6326c0b90e846f304e7ba3e560e9217ff2ad43c27'


def changes(action):
    rows=[("'raw-prime-storage-soc-r1'","'system-read-ack-soc-r1'"),
          ('ventium-raw-prime-storage-cm10-','ventium-system-read-ack-cm10-'),
          ('.parent_build.UI_MODEL','.previous.parent_build.UI_MODEL'),
          ('Path(parent_controls.__file__),','Path(previous_controls.__file__),Path(parent_controls.__file__),')]
    if action=='audit-coremark':
        rows += [('[integration.recipe.FILE]','integration.CHANGES'),
            ('ventium-fprem-sequence.iSZ9BAj4/boundary-ui-soc-r1',
             'ventium-fprem-sequence.iSZ9BAj4/raw-prime-storage-soc-r1')]
    else:rows += [('[build.recipe.FILE]','build.CHANGES')]
    return rows


def derive(action):
    assert build.sha(previous_controls.__file__)==ADAPTER_SHA
    source=previous_controls.derive(action)
    for old,new in changes(action):
        # Some templates receive --soc and do not name its basename; this
        # lineage replacement is intentionally optional, never a guard waiver.
        if old not in source:
            assert old in ("'raw-prime-storage-soc-r1'",'ventium-raw-prime-storage-cm10-'),old
        source=source.replace(old,new)
    compile(source,__file__,'exec')
    return source


def selected_model(soc):
    assert soc==build.ROOT/'system-read-ack-soc-r1'
    start,done=[build.load(soc/n) for n in ('build-started.json','build-closed.json')]
    assert done['passed'] and done['inputs_unchanged'] and done['native_exit']==0
    assert start['parent_model']==build.PARENT_MODEL and start['directed_model']==build.CORE_MODEL
    assert start['changes']==start['processor_rtl_changes']==build.CHANGES and start['added_defines']==[]
    assert start['binding_read_wire']=='kb_fifo_rdreq' and start['controller_sha256']==build.PS2_SHA
    assert start['inherited_cycle_cost']['diagnostic_only'] and not start['canonical_gate_passed']
    assert build.stable(start['pins'])
    assert build.sha(soc/'obj1-speed-q16-parentpolicy/ao486sim_board_posted')==done['binary_sha256']
    return done['binary_sha256']


def namespace(action,model):
    scope=previous_controls.namespace(action,model)
    runner=SimpleNamespace(MODEL=model,PARENT_MODEL=build.PARENT_MODEL,CONTROLLER=build.PS2_SHA,__file__=__file__)
    scope.update(__file__=__file__,previous_controls=previous_controls,build=build,integration=build,
        runner=runner,MODEL=model,PARENT_MODEL=build.PARENT_MODEL,CONTROLLER=build.PS2_SHA)
    return scope


def main():
    ap=argparse.ArgumentParser(description=__doc__,add_help=False)
    ap.add_argument('action',choices=TEMPLATES)
    ap.add_argument('--soc',type=Path,required=True)
    a,forwarded=ap.parse_known_args();soc=a.soc.resolve(strict=True)
    assert __debug__
    model=selected_model(soc)
    sys.argv=[__file__,'--soc',str(soc),*forwarded]
    scope=namespace(a.action,model)
    exec(compile(derive(a.action),__file__,'exec'),scope)
    return scope['main']() if a.action=='input' else 0


if __name__=='__main__':raise SystemExit(main())
