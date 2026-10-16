import ast
from copy import deepcopy
import unittest

import freeze_prime_width_rk_candidate as export


class Freeze(unittest.TestCase):
    def setUp(self):
        self.parent=export.builder.ROOT/'sfetch-boundary-fpga-r1'
        self.sim=export.builder.ROOT/'prime-width-soc-r1'
        self.old=export.builder.load(self.parent/'input-manifest.json')
        self.start=export.builder.load(self.sim/'build-started.json')
        self.closed=export.builder.load(self.sim/'build-closed.json')
        self.defs=(self.sim/'defines.txt').read_text().splitlines()

    def test_actual_closed_profile_and_source_closure(self):
        export.check_profile(self.old,self.start,self.closed,self.defs,export.MODEL)
        text=export.freeze_source();ast.parse(text)
        for token in ('compiled==170','len(payload)==192','native.original.AUX',
                      'mouse.WRAPPER_SHA','Path(template.__file__)','stable()'):
            self.assertIn(token,text)

    def test_stale_failed_or_reconfigured_rejected(self):
        for target,key,value in (('old','variant','old'),('start','directed_model','old'),
            ('start','changes',[]),('start','added_defines',['VEN_UNSAFE']),
            ('closed','passed',False),('closed','native_exit',1),('closed','inputs_unchanged',False),
            ('old','core_mhz',70),('old','write_slots',8),('old','l2_sets',512)):
            args={k:deepcopy(getattr(self,k)) for k in ('old','start','closed')}
            args[target][key]=value
            with self.assertRaises((AssertionError,ValueError,RuntimeError)):
                export.check_profile(args['old'],args['start'],args['closed'],self.defs,export.MODEL)

    def test_only_exact_header_delta(self):
        self.assertEqual(export.CHANGES,['ventium/rtl/core/core_mem_chain.svh'])
        for name in export.CHANGES:
            before=(self.parent/name).read_bytes()
            after=(self.sim/'source'/name.removeprefix('ventium/')).read_bytes()
            self.assertTrue(export.check_delta(name,before,after))
            with self.assertRaises(AssertionError):export.check_delta(name,before,after+b'\n')
        for name in ('ventium/rtl/core/core.sv','ventium/'+export.builder.original.AUX,
                     'flow/src/ven_ps2_mailbox.sv'):
            before=(self.parent/name).read_bytes()
            self.assertFalse(export.check_delta(name,before,before))
            with self.assertRaises(AssertionError):export.check_delta(name,before,before+b'\n')


if __name__=='__main__':unittest.main()
