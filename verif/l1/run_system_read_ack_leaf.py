"""Bounded native miter for the exact system-read ACK derivative.

Preserves the existing guarded runner's ownership, native closure, 32-CPU
compilation, source pins, two profiles and four required failing controls.
This local ACK equivalence is NOT system/FPGA acceptance.
"""
import hashlib
import inspect
import json
from pathlib import Path
import re

import prepare_system_read_ack as recipe
import run_pipe_wait_read_ack_leaf as lifecycle

HERE = Path(__file__).resolve().parent
MODEL = '41f99bcff8125a2caa7fe768f03f242bed1a43323e4d3a190109167248a34e9b'
SAMPLES = 61440
LIFECYCLE_SHA = '566efe0b59f264af94b8f6914439141c5b882e84d2c080f424267042601fbc5f'


def fixture(sources, bus, template):
    recipe.audit_bus(bus)
    changed = {n:recipe.transform(s,n) for n,s in sources.items()}
    consumers = []
    read_owners = []
    i = 0
    for name, states in recipe.OWNERS.items():
        for state in states:
            old, new = [recipe.arm(s, state) for s in (sources[name],changed[name])]
            assert new == re.sub(r'\bmem_ack\b','mem_read_ack',old)
            assert len(re.findall(r'\bmem_read_ack\b',new)) == 1
            consumers.append(f'      {i}: selected_ack=mem_read_ack; // {state}')
            read_owners.append(i)
            i += 1
    walk = changed['core_walk.svh']
    for phase in range(8):
        label = "3'd"+str(phase) if phase<3 else 'default'
        match = re.search(re.escape(label)+r': if \((mem_(?:read_)?ack)\) begin',walk)
        assert match
        ack = match[1]
        assert ack == ('mem_read_ack' if phase in (0,2) else 'mem_ack')
        consumers.append(f'      {i}: selected_ack={ack}; // walk {phase}')
        if phase in (0,2): read_owners.append(i)
        i += 1
    for name,state in (('core_int_deliver.svh','S_INT_PUSH'),('core_tsw.svh','S_TSW_BUSY')):
        assert recipe.arm(sources[name],state) == recipe.arm(changed[name],state)
        consumers.append(f'      {i}: selected_ack=mem_ack; // {state}')
        i += 1
    assert i==30
    core = sources['core.sv']
    read = '  assign mem_read_ack = bus_read_ack && !fx_hold_e;'
    fallback = '  assign mem_read_ack = mem_ack;'
    assert core.count(read)==core.count(fallback)==1
    replacements = dict(FRAGMENT=recipe.assignment(core,'fx_hold_e'),
        ACK=recipe.assignment(core,'mem_ack'),READ_ACK=read,FALLBACK_ACK=fallback,
        CONSUMERS='\n'.join(consumers),READ_OWNER=' || '.join('(owner=='+str(i)+')' for i in read_owners))
    for token,value in replacements.items():
        template=recipe.once(template,'\n'+token+'\n','\n'+value+'\n')
    return template


def check_receipt(root):
    # Use the exact existing closure checks, with this miter's count/markers.
    source=inspect.getsource(lifecycle.check_receipt)
    source=source.replace("'PIPE-WAIT-EQUIV'", "'SYSTEM-READ-EQUIV'")
    namespace=dict(lifecycle.__dict__,SAMPLES=SAMPLES)
    exec(compile(source,__file__,'exec'),namespace)
    pins=namespace['check_receipt'](root)
    start=json.loads((root/'started.json').read_text())
    parent=Path(start['parent'])/'candidate/rtl/core'
    for name in recipe.PARENTS:
        assert (root/name).read_text()==recipe.transform((parent/name).read_text(),name)
    return pins


def main():
    # Fail closed if shared lifecycle admission, timeouts or resource checks
    # change. Text adaptations do not waive any native closure checks.
    assert lifecycle.sha(lifecycle.__file__)==LIFECYCLE_SHA
    source=inspect.getsource(lifecycle.main)
    substitutions=[
      ("changed = recipe.transform(core.read_text())",
       "sources = {n:(core.parent/n).read_text() for n in recipe.PARENTS}\n"
       "    source_paths = [core.parent/n for n in recipe.PARENTS]\n"
       "    assert all(sha(p)==old['pins'][str(p)] for p in source_paths)\n"
       "    changed = {n:recipe.transform(s,n) for n,s in sources.items()}"),
      ("template = HERE/'pipe_wait_read_ack_leaf.svh'", "template = HERE/'system_read_ack_leaf.svh'"),
      ("(out/'core.sv').write_text(changed)","for n,s in changed.items(): (out/n).write_text(s)"),
      ("tb_pipe_wait_read_ack", "tb_system_read_ack"),
      ("fixture(core.read_text(),bus.read_text(),template.read_text())", "fixture(sources,bus.read_text(),template.read_text())"),
      ("Path(extraction.__file__), template,", "Path(lifecycle.__file__), template, *source_paths, *[out/n for n in changed],"),
      ("'PIPE-WAIT-EQUIV'", "'SYSTEM-READ-EQUIV'"),
      ("r'^PIPE-WAIT-OK (.+)$'", "r'^SYSTEM-READ-OK (.+)$'"),
    ]
    for old,new in substitutions:
        assert old in source, old
        source=source.replace(old,new)
    namespace=dict(lifecycle.__dict__)
    namespace.update(__file__=__file__,recipe=recipe,lifecycle=lifecycle,HERE=HERE,
        MODEL=MODEL,SAMPLES=SAMPLES,fixture=fixture,check_receipt=check_receipt)
    exec(compile(source,__file__,'exec'),namespace)
    return namespace['main']()


if __name__=='__main__': raise SystemExit(main())
