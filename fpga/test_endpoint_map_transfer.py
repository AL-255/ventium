"""Exact source transfer and fail-closed profile checks; not FPGA acceptance."""
import ast
import os
from pathlib import Path
import unittest

import build_endpoint_map_soc as native
import freeze_endpoint_map_rk_candidate as freeze
import prepare_endpoint_map_synthesis as timing

ROOT=Path(os.environ.get('ENDPOINT_MAP_ROOT',
    '/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI')).resolve(strict=True)


class Transfer(unittest.TestCase):
    def test_exact_four_file_delta(self):
        self.assertEqual(native.CHANGES,sorted(['rtl/core/core.sv','rtl/core/core_fetch_decode.svh',
            'rtl/core/decode_stages.sv','rtl/mem/ventium_l1_axi.sv']))
        for name in native.CHANGES:
            before=(ROOT/'prime-reg-soc-r1/source'/name).read_bytes()
            after=(ROOT/'endpoint-map-core-r1/candidate'/name).read_bytes()
            self.assertEqual(native.recipe.transform(before.decode(),name).encode(),after)
            self.assertTrue(freeze.check_delta('ventium/'+name,before,after))
            for bad in (before,after+b'\n'):
                with self.assertRaises(Exception): freeze.check_delta('ventium/'+name,before,bad)
            with self.assertRaises(Exception): freeze.check_delta('ventium/'+name,before+b'\n',after)

    def test_no_fifth_delta_or_missing_delta(self):
        self.assertFalse(freeze.check_delta('ventium/rtl/fpu/fpu_top.sv',b'x',b'x'))
        with self.assertRaises(Exception): freeze.check_delta('ventium/rtl/fpu/fpu_top.sv',b'x',b'y')
        with self.assertRaises(ValueError): native.recipe.transform('','rtl/fpu/fpu_top.sv')

    def test_profile_and_closure_contract_retained(self):
        for marker in ('len(hw) == len(set(hw)) == 158','compiled == 170',
                       'core_mhz=40','write_slots=16','len(defs) == len(set(defs)) == 156',
                       'standard_suite=False, hardware_acceptance=False',
                       "old['variant'] == 'prime_reg_flags_timing'",'native.recipe.transform'):
            self.assertIn(marker,freeze.text)
        original=freeze.original.read_text()
        def function(source,name):
            node=next(n for n in ast.parse(source).body if isinstance(n,ast.FunctionDef) and n.name==name)
            # The unchanged guard now describes a four-file transfer rather
            # than three. Compare executable structure, not its docstring.
            if ast.get_docstring(node,clean=False) is not None:
                node.body=node.body[1:]
            return ast.dump(node)
        self.assertEqual(function(original,'check_delta'),function(freeze.text,'check_delta'))

    def test_directed_audit_and_native_builder_still_red(self):
        pins=native.admit(ROOT/'endpoint-map-core-r1',ROOT/'endpoint-map-audit-r1.json')
        self.assertIn(str(ROOT/'endpoint-map-audit-r1.json'),pins)
        self.assertEqual(native.sha(native.base.__file__),native.BUILDER)
        for marker in ('return base.build(root)','len(shared)==102',
                       "'MemoryMax=10G MemorySwapMax=2G'",'verified[\'canonical_gate_native_exit\']==2'):
            self.assertIn(marker,Path(native.__file__).read_text())

    def test_timing_controllers_preserve_resource_lifecycle(self):
        originals={}
        for name,digest in timing.TEMPLATES.items():
            self.assertEqual(timing.sha(ROOT/name),digest)
            originals[name]=(ROOT/name).read_text()
        output=timing.derive(originals,timing.CHANGES)
        for phase in ('synthesis','clock'):
            before=originals['prime-reg-'+phase+'-r1/run.py']
            after=output['endpoint-map-'+phase+'-r1/run.py']
            boundary='owner = None\n'
            self.assertEqual(before[before.index(boundary):],after[after.index(boundary):])
            for marker in ("manifest['core_mhz'] == 40", "VEN_FPGA_BUILD_PROFILE='logic_only'",
                           "len(manifest['hardware_defines']) == 158",
                           'hardware_acceptance=False,implementation_authorized_by_this_controller=False'):
                self.assertIn(marker,after)
        synth=output['endpoint-map-synthesis-r1/run.py']
        before=originals['prime-reg-synthesis-r1/run.py']
        self.assertEqual(before[before.index('host = available()'):before.index("save('started.json'")],
                         synth[synth.index('host = available()'):synth.index("save('started.json'")])
        self.assertIn('endpoint_native.admit',synth)
        self.assertIn("verify['canonical_gate_native_exit']==2",synth)
        self.assertNotIn('1536',synth)  # Do not inherit unrerun FP corpus results.
        self.assertNotIn('regressions-r1',synth)
        self.assertEqual(output['endpoint-map-clock-r1/audit.tcl'],originals['prime-reg-clock-r1/audit.tcl'])
        with self.assertRaises(AssertionError): timing.derive(originals,dict(timing.CHANGES,unreviewed='x'))


if __name__=='__main__': unittest.main()
