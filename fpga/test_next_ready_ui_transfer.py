import unittest

import build_next_ready_ui_soc as build


class Compose(unittest.TestCase):
    def test_only_exact_controller_delta(self):
        before = (build.PARENT/'source'/build.ui.PS2).read_bytes()
        after = (build.UI_PARENT/'source'/build.ui.PS2).read_bytes()
        self.assertTrue(build.check_delta(build.ui.PS2,before,after))
        for left,right in ((before+b'\n',after),(before,after+b'\n'),(after,after)):
            with self.assertRaises(AssertionError): build.check_delta(build.ui.PS2,left,right)
        self.assertFalse(build.check_delta('rtl/core/core.sv',b'cpu',b'cpu'))
        with self.assertRaises(AssertionError): build.check_delta('rtl/core/core.sv',b'cpu',b'changed')

    def test_identical_qualified_host_and_binding(self):
        start = build.load(build.PARENT/'build-started.json')
        old = build.Path(start['host']).read_text()
        accepted = build.Path(build.load(build.UI_PARENT/'build-started.json')['host'])
        self.assertEqual(build.ui.transform_host(old),accepted.read_text())
        raw = (build.ui.host_recipe.HERE/'pc_keyboard_retained.h').read_text()
        self.assertEqual(build.bound.binding(raw),(accepted.parent/'pc_keyboard_retained.h').read_text())
        with self.assertRaises(ValueError): build.ui.transform_host(old+'\n')


if __name__ == '__main__': unittest.main()
