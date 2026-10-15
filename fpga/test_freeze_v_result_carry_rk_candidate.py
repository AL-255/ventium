"""Reject stale PC provenance, source drift and hardware-profile changes."""
from copy import deepcopy
import json
from pathlib import Path
import unittest

import freeze_v_result_carry_rk_candidate as f

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Freeze(unittest.TestCase):
    def setUp(self):
        self.old=json.loads((ROOT/'pipe-wait-aux-mouse-fpga-r1/input-manifest.json').read_text())
        self.start=json.loads((ROOT/'v-result-carry-soc-r1/build-started.json').read_text())
        self.closed=json.loads((ROOT/'v-result-carry-soc-r1/build-closed.json').read_text())
        self.defs=(ROOT/'v-result-carry-soc-r1/defines.txt').read_text().splitlines()

    def test_actual_closed_source_profile(self):
        f.check_profile(self.old,self.start,self.closed,self.defs)

    def test_stale_core_failed_build_and_extra_deltas_rejected(self):
        for target,key,value in (('old','variant','pipe_wait_read_ack_timing'),
                                ('start','directed_model','old'),('start','parent_model','old'),
                                ('start','changes',[]),('start','added_defines',['VEN_UNSAFE']),
                                ('closed','passed',False),('closed','native_exit',1),
                                ('closed','inputs_unchanged',False),('closed','binary_sha256','old')):
            values={k:deepcopy(getattr(self,k)) for k in ('old','start','closed')}
            values[target][key]=value
            with self.assertRaises((AssertionError,ValueError,RuntimeError)):
                f.check_profile(values['old'],values['start'],values['closed'],self.defs)

    def test_no_undeclared_hardware_profile_changes(self):
        for key,value in (('core_mhz',70),('write_slots',8),('l2_sets',512),
                          ('hardware_defines',self.old['hardware_defines'][:-1])):
            old=deepcopy(self.old);old[key]=value
            with self.assertRaises((AssertionError,ValueError,RuntimeError)):
                f.check_profile(old,self.start,self.closed,self.defs)

    def test_only_two_exact_payloads_change(self):
        parent=ROOT/'pipe-wait-aux-mouse-fpga-r1'
        source=ROOT/'v-result-carry-soc-r1/source'
        for name in f.CHANGES:
            before=(parent/name).read_bytes();after=(source/name.removeprefix('ventium/')).read_bytes()
            self.assertTrue(f.check_delta(name,before,after))
            with self.assertRaises(AssertionError):f.check_delta(name,before,after+b'\n')
        for name in ('flow/src/ven_mgmt_axil.v','flow/src/ven_ps2_mailbox.sv','ventium/'+f.native.AUX):
            before=(parent/name).read_bytes()
            self.assertFalse(f.check_delta(name,before,before))
            with self.assertRaises(AssertionError):f.check_delta(name,before,before+b'\n')


if __name__=='__main__':unittest.main()
