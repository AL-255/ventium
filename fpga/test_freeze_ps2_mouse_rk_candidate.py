"""Test export-delta admission, not mouse behavior or FPGA qualification."""
from contextlib import ExitStack
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import freeze_ps2_mouse_rk_candidate as export
from freeze_rk_candidate import FreezeError, sha256

SOURCE = None


class MouseExportTests(unittest.TestCase):
    def setUp(self):
        # Small synthetic inputs exercise the export boundary. The real recipe
        # and expanded project are additionally checked by the native freeze.
        self.parent = {'ventium/unit%d.sv' % n: b'unchanged' for n in range(187)}
        self.overlay = {}
        transforms, hashes = {}, {}
        for name in export.TRANSFORMS:
            before = ('before:' + name).encode()
            after = before + b':mouse'
            self.parent['flow/' + name] = before
            self.overlay[name] = after
            hashes[name] = sha256(before)
            transforms[name] = lambda text: text + ':mouse'
        self.overlay.update({name: b'module mouse; endmodule' for name in export.ADDED})
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(export, 'TRANSFORMS', transforms))
        self.stack.enter_context(patch.object(export.recipe, 'BASE', hashes))

    def test_exact_delta_and_no_input_mutation(self):
        before = dict(self.parent)
        result = export.integrate(self.parent, self.overlay)
        self.assertEqual(self.parent, before)
        self.assertEqual(len(result), 192)
        changed = {n for n in before if before[n] != result[n]}
        self.assertEqual(changed, {'flow/' + n for n in export.TRANSFORMS})
        self.assertEqual(set(result) - set(before), {'flow/' + n for n in export.ADDED})

    def test_missing_overlay(self):
        for name in self.overlay:
            with self.subTest(name=name), self.assertRaisesRegex(FreezeError, 'incomplete/extra'):
                export.integrate(self.parent, {n: b for n, b in self.overlay.items() if n != name})

    def test_extra_overlay_cannot_edit_processor(self):
        for name in ('ventium/rtl/core/core.sv', 'src/other.v', 'hw/clocks.xdc'):
            with self.subTest(name=name), self.assertRaisesRegex(FreezeError, 'incomplete/extra'):
                export.integrate(self.parent, dict(self.overlay, **{name: b'extra'}))

    def test_each_predecessor_is_checked(self):
        for name in export.TRANSFORMS:
            parent = dict(self.parent, **{'flow/' + name: b'drift'})
            with self.subTest(name=name), self.assertRaisesRegex(FreezeError, 'predecessor drift'):
                export.integrate(parent, self.overlay)

    def test_each_transformed_payload_is_checked(self):
        for name in export.TRANSFORMS:
            overlay = dict(self.overlay, **{name: self.overlay[name] + b'\nunsafe delta'})
            with self.subTest(name=name), self.assertRaisesRegex(FreezeError, 'unreviewed overlay delta'):
                export.integrate(self.parent, overlay)

    def test_wrong_count_and_reapplication(self):
        for parent in ({}, dict(self.parent, extra=b'x'), export.integrate(self.parent, self.overlay)):
            with self.assertRaisesRegex(FreezeError, 'parent payload count'):
                export.integrate(parent, self.overlay)

    def test_existing_added_file_is_rejected_even_with_right_count(self):
        for name in export.ADDED:
            parent = dict(self.parent)
            del parent['ventium/unit0.sv']
            parent['flow/' + name] = b'already present'
            with self.subTest(name=name), self.assertRaisesRegex(FreezeError, 'already integrated'):
                export.integrate(parent, self.overlay)


class ExpandedProjectTests(unittest.TestCase):
    def setUp(self):
        if SOURCE is None:
            self.skipTest('supply --source for real expanded-project negative controls')
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(strict=True), scratch)
        temp = tempfile.TemporaryDirectory(prefix='mouse-project-contract-', dir=scratch)
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.flow = self.root/'flow'
        shutil.copytree(SOURCE/'flow', self.flow)
        self.defs = self.root/'defines.txt'
        shutil.copyfile(SOURCE/'defines.txt', self.defs)
        self.project = self.flow/'hw/create_project.tcl'

    def check(self, passed, diagnostic):
        result = subprocess.run(['tclsh', str(export.REPO/'fpga/test_ps2_mouse_rk_wrapper.tcl'),
            str(SOURCE/'ventium/fpga/create_project_3mhz_wrapper.tcl'), str(self.flow), str(self.defs),
            str(SOURCE/'ventium'), str(SOURCE/'template'), 'logic_only'],
            capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode == 0, passed, result.stdout + result.stderr)
        self.assertIn(diagnostic, result.stdout + result.stderr)

    def test_real_project_missing_duplicate_and_positive(self):
        original = self.project.read_text()
        self.check(True, 'MOUSE-PROJECT-SOURCE-CONTRACT-OK')
        for name in export.ADDED:
            for replacement in ('', name + ' ' + name):
                with self.subTest(name=name, replacement=replacement):
                    self.assertEqual(original.count(name), 1)
                    self.project.write_text(original.replace(name, replacement))
                    self.check(False, 'missing or duplicate mouse source')
        self.project.write_text(original)
        self.check(True, 'MOUSE-PROJECT-SOURCE-CONTRACT-OK')

    def test_real_project_missing_file(self):
        target = self.flow/export.ADDED[0]
        # Only this test's disposable copy is removed, never a frozen source.
        target.unlink()
        self.check(False, 'missing mouse RTL file')

    def test_inherited_profile_checks_still_reject_drift(self):
        original = self.defs.read_text()
        self.assertEqual(original.count('VEN_FE_PIPE\n'), 1)
        self.defs.write_text(original.replace('VEN_FE_PIPE\n', 'VEN_CACHE_HALF\n'))
        self.check(False, 'refusing FPGA build: VEN_CACHE_HALF is retired; use the full P5 L1 configuration')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path)
    args, remaining = parser.parse_known_args()
    SOURCE = args.source.resolve(strict=True) if args.source else None
    unittest.main(argv=[__file__, *remaining])
