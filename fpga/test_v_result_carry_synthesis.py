"""Check generated CAD controller scope, identities and unchanged resource guards."""
import json
import unittest

import prepare_v_result_carry_synthesis as p


class Controller(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original={n:(p.ROOT/n).read_text() for n in p.TEMPLATES}
        old=json.loads((p.ROOT/'pipe-wait-fpga-r1/input-manifest.json').read_text())
        new=json.loads((p.ROOT/'v-result-carry-fpga-r1/input-manifest.json').read_text())
        a={r['frozen']:r['sha256'] for r in old['files']};b={r['frozen']:r['sha256'] for r in new['files']}
        cls.changed={n:b[n] for n in a if a[n]!=b[n]};cls.added={n:b[n] for n in b if n not in a}
        cls.outputs=p.derive(cls.original,cls.changed,cls.added)

    def test_current_export_scope_is_not_an_isolated_core_comparison(self):
        self.assertEqual(len(self.changed),6);self.assertEqual(len(self.added),2)
        run=self.outputs['v-result-carry-synthesis-r3/run.py']
        self.assertIn("manifest['processor_platform_simulator_sha256'] == model",run)
        self.assertIn('no isolated timing-gain claim',run)
        self.assertIn('pins.update(native.evidence(proof,core))',run)
        self.assertIn("len(matched['rows'])==108",run)
        self.assertIn("cm_audit['no_oom']",run)
        self.assertIn("assert not lint['full_soc_lint']",run)

    def test_lifecycle_and_admission_identical(self):
        old=self.original['pipe-wait-synthesis-r1/run.py'];run=self.outputs['v-result-carry-synthesis-r3/run.py']
        p.guarded(run,old)
        for anchor in ('owner = None\n','host = available()\n'):
            if anchor.startswith('owner'):self.assertEqual(run[run.index(anchor):],old[old.index(anchor):])
            else:
                end="(root/'once').mkdir()"
                self.assertEqual(run[run.index(anchor):run.index(end)],old[old.index(anchor):old.index(end)])
        for before,after in (("VENTIUM_VIVADO_MEMORY_MAX='8G'","VENTIUM_VIVADO_MEMORY_MAX='16G'"),
                             ('if free < 4*gib:','if free < 1*gib:'),
                             ('memory+swap > 13*gib','memory+swap > 30*gib')):
            with self.assertRaises(AssertionError):p.guarded(run.replace(before,after),old)

    def test_native_source_audit_includes_added_mouse_and_v_datapath(self):
        audit=self.outputs['v-result-carry-synthesis-r3/audit_closed.py']
        for n in ('flow/src/ven_ps2_mailbox.sv','flow/src/ven_ps2_device.sv','ventium/rtl/core/v_pipe.sv'):
            self.assertIn(n,audit)
        self.assertIn('isolated_rtl_gain_claimed=False',audit)
        self.assertIn('matched_mapper=True',audit)
        self.assertIn("len(new_rows) == len(manifest['files']) == 192",audit)
        for n,text in self.outputs.items():
            compile(text,n,'exec')
            self.assertEqual(text,(p.ROOT/n).read_text())


if __name__=='__main__':unittest.main()
