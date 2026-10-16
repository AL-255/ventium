"""Check source/profile identity and reject stale or extra FPGA edits."""
import ast
from copy import deepcopy
from pathlib import Path
import unittest

import freeze_sfetch_boundary_rk_candidate as export

ROOT=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4').resolve(strict=True)


class Freeze(unittest.TestCase):
    def setUp(self):
        self.parent=ROOT/'v-result-carry-posted-mouse-fpga-r1'
        self.sim=ROOT/'sfetch-boundary-soc-r1'
        self.old=export.builder.load(self.parent/'input-manifest.json')
        self.start=export.builder.load(self.sim/'build-started.json')
        self.closed=export.builder.load(self.sim/'build-closed.json')
        self.defs=(self.sim/'defines.txt').read_text().splitlines()

    def test_actual_profile(self):
        export.check_profile(self.old,self.start,self.closed,self.defs,export.MODEL)
        ast.parse(export.freeze_source())

    def test_stale_failed_or_reconfigured_rejected(self):
        for target,key,value in (('old','variant','old'),('start','directed_model','old'),
            ('start','changes',[]),('start','added_defines',['VEN_UNSAFE']),
            ('closed','passed',False),('closed','native_exit',1),('closed','inputs_unchanged',False),
            ('old','core_mhz',70),('old','write_slots',8),('old','l2_sets',512)):
            args={k:deepcopy(getattr(self,k)) for k in ('old','start','closed')}
            args[target][key]=value
            with self.assertRaises((AssertionError,ValueError,RuntimeError)):
                export.check_profile(args['old'],args['start'],args['closed'],self.defs,export.MODEL)

    def test_only_exact_two_file_delta(self):
        for name in export.CHANGES:
            before=(self.parent/name).read_bytes()
            after=(self.sim/'source'/name.removeprefix('ventium/')).read_bytes()
            self.assertTrue(export.check_delta(name,before,after))
            with self.assertRaises(AssertionError): export.check_delta(name,before,after+b'\n')
        for name in (export.previous.mouse.repair.WRAPPER,'flow/src/ven_ps2_mailbox.sv',
                     'ventium/'+export.builder.previous.AUX):
            before=(self.parent/name).read_bytes()
            self.assertFalse(export.check_delta(name,before,before))
            with self.assertRaises(AssertionError): export.check_delta(name,before,before+b'\n')


if __name__=='__main__':unittest.main()
