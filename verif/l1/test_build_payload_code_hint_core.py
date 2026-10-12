"""Host admission tests; no core compiler, guest, or vendor tool is launched."""
import copy
import json
import os
from pathlib import Path
import unittest

import build_payload_code_hint_core as builder


class CoreAdmission(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.parent = Path(os.environ['PAYLOAD_CODE_HINT_PARENT']).resolve().parent
        cls.before = json.loads((cls.parent/'build-started.json').read_text())

    def command(self, original=None):
        root = self.parent.parent/'not-created-host-test'
        return builder.build_command(original or self.before['command'], self.parent, root,
                                     Path(self.before['host']), root/'private-host.cpp')

    def test_only_one_define_added_to_preserved_command(self):
        command, definitions = self.command()
        self.assertEqual(len(definitions), 151)
        self.assertEqual(definitions[-1], builder.recipe.FLAG)
        expected = builder.common.relocate(self.before['command'], self.parent,
            self.parent.parent/'not-created-host-test', Path(self.before['host']),
            self.parent.parent/'not-created-host-test/private-host.cpp')
        recovered = [arg.replace(' +define+'+builder.recipe.FLAG, '') for arg in command]
        self.assertEqual(recovered, expected)
        self.assertIn('VL_J=32', command)

    def test_missing_fast_mode_or_disabled_assertions_rejected(self):
        for token in ('+define+VEN_FE_PIPE ', '--assert ', '+define+VEN_SYS_FASTPATH_RELOC '):
            command = [arg.replace(token, '') for arg in self.before['command']]
            with self.subTest(token=token), self.assertRaises(AssertionError):
                self.command(command)

    def test_duplicate_new_flag_rejected(self):
        command = [arg+' +define+'+builder.recipe.FLAG if arg.startswith('VL_EXTRA_DEFINES=') else arg
                   for arg in self.before['command']]
        with self.assertRaises(AssertionError):
            self.command(command)

    def test_cache_must_pass_all_native_variants_and_identical_cycles(self):
        good = dict(passed=True, pins_unchanged=True, all_clock_interface_observations_identical=True,
            variants=[dict(name=name, build_exit=0, positive_exit=0, negative_exit=1,
                           cycles_sha256='a'*64, coverage=list(builder.cache_driver.MARKERS))
                      for name in ('control', 'off', 'on')])
        builder.cache_passed(good)
        for mutation in ('missing-case', 'build-failure', 'run-failure', 'negative-pass', 'different-cycles', 'missing-coverage'):
            bad = copy.deepcopy(good)
            if mutation == 'missing-case': bad['variants'].pop()
            if mutation == 'build-failure': bad['variants'][0]['build_exit'] = 1
            if mutation == 'run-failure': bad['variants'][1]['positive_exit'] = 1
            if mutation == 'negative-pass': bad['variants'][2]['negative_exit'] = 0
            if mutation == 'different-cycles': bad['variants'][2]['cycles_sha256'] = 'b'*64
            if mutation == 'missing-coverage': bad['variants'][2]['coverage'].pop()
            with self.subTest(mutation=mutation), self.assertRaises(AssertionError):
                builder.cache_passed(bad)


if __name__ == '__main__':
    unittest.main()
