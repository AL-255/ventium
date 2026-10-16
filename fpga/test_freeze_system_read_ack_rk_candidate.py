import copy
import unittest
import freeze_system_read_ack_rk_candidate as freeze
from freeze_rk_candidate import FreezeError


class Freeze(unittest.TestCase):
    def setUp(self):
        self.old=freeze.native.load(freeze.native.ROOT/'raw-prime-storage-fpga-r1/input-manifest.json')
        soc=freeze.native.ROOT/'system-read-ack-soc-r1'
        self.start=freeze.native.load(soc/'build-started.json')
        self.closed=freeze.native.load(soc/'build-closed.json')
        self.defs=(soc/'defines.txt').read_text().splitlines()

    def test_profile_and_failures_retained(self):
        freeze.check_profile(self.old,self.start,self.closed,self.defs)
        for field in ('canonical_gate_passed','legacy_aggregate_gate_passed'):
            changed=copy.deepcopy(self.start);changed[field]=True
            with self.assertRaises(FreezeError):freeze.check_profile(self.old,changed,self.closed,self.defs)

    def test_all_payloads_preserved_except_nine_exact_core_deltas(self):
        parent=freeze.native.ROOT/'raw-prime-storage-fpga-r1'
        soc=freeze.native.ROOT/'system-read-ack-soc-r1/source'
        changes=[]
        for row in self.old['files']:
            name=row['frozen'];before=(parent/name).read_bytes();after=before
            if name.startswith('ventium/') and name in freeze.CHANGES:
                after=(soc/name.removeprefix('ventium/')).read_bytes()
            if freeze.check_delta(name,before,after):changes.append(name)
        self.assertEqual(sorted(changes),freeze.CHANGES)
        self.assertEqual(len(changes),9)

    def test_native_seal_guards_unchanged(self):
        source=freeze.adapted_freeze()
        for required in ('compiled == 170','len(payload) == 192','source_closure',
                         'closed_owner(build_unit',"pins in (began['pins']",'stable();',
                         'changed_flow_payloads=[]',"full_wrapper_elaborated=False"):
            self.assertIn(required,source)


if __name__=='__main__':unittest.main()
