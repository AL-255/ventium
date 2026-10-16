"""Fail closed on stale CPU provenance or undeclared FPGA source/profile deltas."""
from copy import deepcopy
from pathlib import Path
import unittest

import freeze_backing_direction_rk_candidate as f

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Freeze(unittest.TestCase):
    def setUp(self):
        self.parent=ROOT/'v-result-carry-posted-mouse-fpga-r1'
        self.sim=ROOT/'backing-direction-soc-r1'
        self.old=f.native.load(self.parent/'input-manifest.json')
        self.start=f.native.load(self.sim/'build-started.json')
        self.closed=f.native.load(self.sim/'build-closed.json')
        self.defs=(self.sim/'defines.txt').read_text().splitlines()
        self.model=self.closed['binary_sha256']

    def test_actual_profile(self):
        f.check_profile(self.old,self.start,self.closed,self.defs,self.model)

    def test_stale_or_failed_build_rejected(self):
        for target,key,value in (('old','variant','old'),('start','directed_model','old'),
            ('start','changes',[]),('start','added_defines',['VEN_UNSAFE']),
            ('closed','passed',False),('closed','native_exit',1),('closed','inputs_unchanged',False)):
            args={k:deepcopy(getattr(self,k)) for k in ('old','start','closed')}
            args[target][key]=value
            with self.assertRaises((AssertionError,ValueError,RuntimeError)):
                f.check_profile(args['old'],args['start'],args['closed'],self.defs,self.model)

    def test_clock_geometry_or_defines_rejected(self):
        for key,value in (('core_mhz',70),('write_slots',8),('l2_sets',512),
                          ('hardware_defines',self.old['hardware_defines'][:-1])):
            old=deepcopy(self.old);old[key]=value
            with self.assertRaises((AssertionError,ValueError,RuntimeError)):
                f.check_profile(old,self.start,self.closed,self.defs,self.model)

    def test_only_exact_l1_delta(self):
        name=f.CHANGES[0]
        before=(self.parent/name).read_bytes()
        after=(self.sim/'source'/name.removeprefix('ventium/')).read_bytes()
        self.assertTrue(f.check_delta(name,before,after))
        with self.assertRaises(AssertionError):f.check_delta(name,before,after+b'\n')
        for name in (f.mouse.repair.WRAPPER,'flow/src/ven_ps2_mailbox.sv',
                     'ventium/'+f.native.previous.AUX):
            before=(self.parent/name).read_bytes()
            self.assertFalse(f.check_delta(name,before,before))
            with self.assertRaises(AssertionError):f.check_delta(name,before,before+b'\n')


if __name__=='__main__':unittest.main()
