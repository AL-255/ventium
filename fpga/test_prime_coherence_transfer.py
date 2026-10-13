"""Exact composite transfer and fail-closed admission; not FPGA acceptance."""
import ast
import os
from pathlib import Path
import unittest

import build_prime_coherence_soc as native
import freeze_prime_coherence_rk_candidate as freeze
import prepare_prime_coherence_synthesis as timing

ROOT = Path(os.environ.get('PRIME_COHERENCE_ROOT',
    '/home/yukidama/external/tmp/ventium-load-read-ack.GyWDDtiI')).resolve(strict=True)


class PrimeCoherenceTransfer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.inputs = {p: (ROOT/'fp-wide-context-soc-r1/source'/p).read_text()
                      for p in native.recipe.PARENTS}

    def test_composite_three_file_delta(self):
        after = native.recipe.validate_sources(self.inputs)
        self.assertEqual(native.CHANGES, sorted([
            'rtl/core/core_mem_chain.svh', *native.recipe.hint.CHANGES]))
        for name in native.CHANGES:
            expected = (ROOT/'prime-coherence-core-r1/candidate'/name).read_bytes()
            self.assertEqual(after[name].encode(), expected)
            before = self.inputs[name].encode()
            self.assertTrue(freeze.check_delta('ventium/'+name, before, expected))
            for bad in (before, expected+b'\n'):
                with self.assertRaises(Exception):
                    freeze.check_delta('ventium/'+name, before, bad)
            with self.assertRaises(ValueError):
                native.recipe.transform(self.inputs[name]+'\n', name)

    def test_full_source_contract_not_only_changed_headers(self):
        for name in self.inputs:
            with self.subTest(name=name):
                bad = dict(self.inputs); bad[name] += '\n'
                with self.assertRaises(ValueError):
                    native.recipe.validate_sources(bad)
        # Missing or already-applied first-stage changes must not silently pass.
        bad = dict(self.inputs); bad.pop('rtl/ventium_top.sv')
        with self.assertRaises(ValueError):
            native.recipe.validate_sources(bad)
        bad = dict(self.inputs)
        key = 'rtl/core/core_mem_chain.svh'
        bad[key] = native.recipe.transform(bad[key], key)
        with self.assertRaises(ValueError):
            native.recipe.validate_sources(bad)

    def test_no_other_delta_or_inherited_acceptance(self):
        name = 'ventium/rtl/core/core.sv'
        self.assertFalse(freeze.check_delta(name, b'x', b'x'))
        with self.assertRaises(Exception):
            freeze.check_delta(name, b'x', b'y')
        for marker in ('len(hw) == len(set(hw)) == 158', 'compiled == 170',
                       'standard_suite=False, hardware_acceptance=False', 'core_mhz=40',
                       "'fp_wide_context_timing'"):
            self.assertIn(marker, freeze.text)

    def test_native_admission_and_guarded_build_preserved(self):
        original = native.original.read_text()
        functions = lambda text: {n.name: ast.dump(n) for n in ast.parse(text).body
                                  if isinstance(n, ast.FunctionDef)}
        self.assertEqual(functions(original)['regressions'],
                         functions(native.text)['regressions'])
        for start, end in (('    shared=', '    host='),
                           ('    command=', '    for p in (*files,')):
            self.assertEqual(original.split(start)[1].split(end)[0],
                             native.text.split(start)[1].split(end)[0])
        for marker in ('return base.build(root)', 'recipe.validate_sources',
                       "before['changes']==recipe.hint.CHANGES", 'pins.update(admit_smc(core,smc))'):
            self.assertIn(marker, native.text)

    def test_actual_cold_smc_admission(self):
        pins = native.admit_smc(ROOT/'prime-coherence-core-r1', ROOT/'prime-coherence-smc-r1')
        self.assertIn(str(ROOT/'prime-coherence-smc-r1/audit.json'), pins)
        with self.assertRaises(AssertionError):
            native.admit_smc(ROOT/'mc-local-core-r1', ROOT/'prime-coherence-smc-r1')

    def test_timing_controller_guards_and_two_parent_deltas(self):
        original = {}
        for name, digest in timing.TEMPLATES.items():
            self.assertEqual(native.sha(ROOT/name), digest)
            original[name] = (ROOT/name).read_text()
        result = timing.derive(original, {'ventium/'+n: native.recipe.CHILDREN[n]
                                         for n in native.CHANGES})
        self.assertEqual(len(result), 5)
        for phase in ('synthesis','clock'):
            text = result['prime-coherence-'+phase+'-r1/run.py']
            timing.guarded(text, original['fp-wide-context-'+phase+'-r1/run.py'])
            self.assertIn("manifest['variant'] == 'prime_coherence_timing'", text)
        synth = result['prime-coherence-synthesis-r1/run.py']
        self.assertIn('changes='+repr(native.CHANGES), synth)
        self.assertIn("assert core['changes']=="+repr(native.recipe.hint.CHANGES), synth)
        self.assertIn("assert prepared['added_defines']==[]", synth)
        self.assertIn("assert shutil.disk_usage(root).free > 6*gib", synth)
        self.assertIn("assert all(r['parent_ticks']==r['candidate_ticks']", synth)
        self.assertIn('(-5.988)', result['prime-coherence-clock-r1/audit_closed.py'])


if __name__ == '__main__':
    unittest.main()
