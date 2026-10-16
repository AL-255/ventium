"""Seal the exact system ACK derivative, preserving both input-device repairs.

Reuse the complete source/payload/preprocessing seal, including native build
ownership and independently graded cold integration controls. No deployment or
timing qualification is inherited from the older FPGA source set.
"""
import argparse
import inspect
import json
from pathlib import Path

import build_system_read_ack_soc as native
import raw_prime_storage_evidence as parent_evidence
import freeze_raw_prime_storage_rk_candidate as previous

MODEL='3d94caaa60d85a2cd13823a24ee629d76a08fdfb0ed1795c5aed8e0f7f65a17f'
VARIANT='system_read_ack_retained_input_unqualified'
PARENT=parent_evidence.MANIFEST
CHANGES=sorted('ventium/'+n for n in native.CHANGES)
INJECTOR,CONTROLLER=previous.INJECTOR,previous.CONTROLLER
require=previous.require


def check_delta(name,before,after):
    return native.check_delta(name.removeprefix('ventium/'),before,after)


def check_profile(old,start,closed,definitions):
    require(old['variant']==parent_evidence.VARIANT and old['qualification']=='UNQUALIFIED','wrong parent profile')
    require(old['processor_platform_simulator_sha256']==native.PARENT_MODEL,'wrong parent processor')
    require((old['core_mhz'],old['write_slots'],old['l2_sets'])==(40,16,1024),'geometry changed')
    require(start['parent_model']==native.PARENT_MODEL and start['directed_model']==native.CORE_MODEL,'wrong compiled closure')
    require(start['changes']==native.CHANGES and start['added_defines']==[],'extra deltas')
    require(start['controller_sha256']==native.PS2_SHA and start['binding_read_wire']=='kb_fifo_rdreq','input repair lost')
    require(not start['canonical_gate_passed'] and not start['legacy_aggregate_gate_passed'],'failure policy changed')
    require(closed['passed'] and closed['native_exit']==0 and closed['inputs_unchanged'] and
            closed['binary_sha256']==MODEL,'native PC not closed')
    native.transfer.check_definitions(start['command'],definitions)
    hw=old['hardware_defines']
    require(len(hw)==len(set(hw))==159 and set(hw)-{'SYNTHESIS','VTM_NO_DPI'}==set(definitions),'profile mismatch')


def adapted_freeze():
    assert native.sha(previous.__file__)=='d959d6993f87655d861f04efe571fb104d762197742ed9b7cddd5c1ee4313385'
    source=inspect.getsource(previous.freeze)
    for old,new in (
        ("'raw-prime-storage-soc-r1'","'system-read-ack-soc-r1'"),
        ("'raw-prime-storage-input-r1'","'system-read-ack-input-r1'"),
        ('changed_flow_payloads=[INJECTOR]','changed_flow_payloads=[]'),
        ('read(Path(__file__).resolve());','read(Path(__file__).resolve()); read(Path(previous.__file__).resolve());'),
        ('Exact RAW-storage/retained-8042/injector composition. Posted mouse wrapper unchanged. No timing, full-wrapper, guest or physical acceptance inherited.',
         'Exact nine-file system read ACK cut. Retained 8042, keyboard retry and posted mouse wrapper unchanged. No timing, full-wrapper, guest or physical acceptance inherited.'),
    ):
        assert source.count(old)==1,old
        source=source.replace(old,new)
    return source


def freeze(parent,sim,build_unit,out):
    scope=dict(previous.__dict__,__file__=__file__,previous=previous,native=native,
        parent_evidence=parent_evidence,MODEL=MODEL,VARIANT=VARIANT,PARENT=PARENT,
        CHANGES=CHANGES,check_delta=check_delta,check_profile=check_profile)
    exec(compile(adapted_freeze(),__file__,'exec'),scope)
    return scope['freeze'](parent,sim,build_unit,out)


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    for name in ('parent','sim','out'):ap.add_argument('--'+name,type=Path,required=True)
    ap.add_argument('--build-unit',required=True)
    a=ap.parse_args()
    print(json.dumps(freeze(a.parent.resolve(strict=True),a.sim.resolve(strict=True),a.build_unit,a.out.resolve())))
