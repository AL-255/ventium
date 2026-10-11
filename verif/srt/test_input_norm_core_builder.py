"""Host-side source and admission checks; not native processor acceptance."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_input_norm_core as builder


class BuilderContracts(unittest.TestCase):
    def setUp(self):
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(), scratch)
        self.temp = tempfile.TemporaryDirectory(prefix='srt-input-builder-test-', dir=scratch)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_pin_checks_detect_changed_source(self):
        source = self.root/'source.sv'
        source.write_text('module original; endmodule\n')
        pins = {str(source): builder.sha(source)}
        self.assertTrue(builder.stable(pins))
        source.write_text('module changed; endmodule\n')
        self.assertFalse(builder.stable(pins))

    def test_source_inventory_rejects_symlink(self):
        source = self.root/'source'
        source.mkdir()
        native = source/'original.sv'
        native.write_text('module original; endmodule\n')
        self.assertEqual(builder.candidate_files(source), [native])
        (source/'alias.sv').symlink_to(native)
        with self.assertRaises(AssertionError):
            builder.candidate_files(source)

    def test_build_refuses_unowned_guard_before_launch(self):
        (self.root/'prepared.json').write_text(json.dumps({}))
        with patch.dict(os.environ, {'INVOCATION_ID': '0'*32}), \
             patch.object(builder.subprocess, 'run',
                          side_effect=subprocess.CalledProcessError(1, 'guard')) as native:
            with self.assertRaises(subprocess.CalledProcessError):
                builder.build(self.root)
        self.assertEqual(native.call_count, 1)
        self.assertEqual(native.call_args.args[0][-1], '--is-active')
        self.assertEqual(native.call_args.kwargs['pass_fds'], (9,))
        self.assertFalse((self.root/'build-started.json').exists())
        self.assertFalse((self.root/'obj').exists())

    def test_build_reapplication_is_refused_before_guard(self):
        (self.root/'prepared.json').write_text(json.dumps({}))
        (self.root/'build-started.json').write_text(json.dumps({}))
        with patch.object(builder.subprocess, 'run') as native:
            with self.assertRaises(AssertionError):
                builder.build(self.root)
        native.assert_not_called()


if __name__ == '__main__':
    unittest.main()

