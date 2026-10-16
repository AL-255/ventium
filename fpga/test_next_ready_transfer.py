import ast
import unittest

import build_next_ready_soc as build


class TransferTests(unittest.TestCase):
    def test_source_only_one_delta(self):
        self.assertEqual(build.CHANGES, ['rtl/mem/ven_l1d.sv'])
        self.assertFalse(build.check_delta('rtl/core/core.sv', b'unchanged', b'unchanged'))
        with self.assertRaises(AssertionError):
            build.check_delta('rtl/core/core.sv', b'unchanged', b'changed')
        with self.assertRaises(AssertionError):
            build.check_delta(build.recipe.FILE, b'unpinned parent', b'changed')

    def test_preserve_private_model_and_full_source_guards(self):
        text = build.prepare_source()
        ast.parse(text)
        for guard in ('len(shared)==102', 'check_definitions(command,', "'sim_next_ready_'",
                      'check_delta(n,', 'stable(started[', 'sha(source/AUX)==AUX_SHA'):
            self.assertIn(guard, text)
        self.assertIn('Canonical gate remains FAIL', text)
        self.assertNotIn("old['parent_profile']=='pipe-wait'", text)

    def test_profile_rejects_disabled_fast_path_and_geometry_drift(self):
        import json
        path = build.leaf.ROOT/'sfetch-boundary-soc-r1/build-started.json'
        command = json.loads(path.read_text())['command']
        expected = (path.parent/'defines.txt').read_text().splitlines()
        self.assertEqual(len(build.check_definitions(command, expected)), 157)
        for old,new in (('-GBOARD_WRITE_SLOTS=16','-GBOARD_WRITE_SLOTS=1'),
                        ('-DVEN_SYS_FASTPATH_RELOC','-DUNRELATED')):
            self.assertIn(old, command)
            with self.assertRaises(AssertionError):
                build.check_definitions([new if s==old else s for s in command], expected)


if __name__ == '__main__': unittest.main()
