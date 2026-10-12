"""Check exact DMA repair, partial controls and clean canonical-overlay transfer."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import prepare_dma_declaration_order as recipe

REPO = Path(__file__).resolve().parents[1]
SUBMODULE = REPO / '3rd-party/ao486_MiSTer'
FIXED = '262a8d0fcf788c0f7ea62e8e4734f7530446cea244a53c9aa466447cac10f2df'
OVERLAY = REPO / 'ao486-sim/patches/ao486_MiSTer_ventium.patch'


class DeclarationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        pinned = subprocess.check_output(
            ['git', 'ls-tree', 'HEAD', '3rd-party/ao486_MiSTer'], cwd=REPO,
            text=True).split()[2]
        cls.base = subprocess.check_output(
            ['git', 'show', pinned + ':rtl/soc/dma.v'], cwd=SUBMODULE, text=True)
        cls.parent = ('`default_nettype wire  // added for Vivado project-flow synth '
                      '(leak-proof; Quartus-style expects wire)\n' + cls.base)
        assert hashlib.sha256(cls.parent.encode()).hexdigest() == recipe.PARENT
        cls.fixed = recipe.transform(cls.parent)

    def test_exact_result(self):
        self.assertEqual(hashlib.sha256(self.fixed.encode()).hexdigest(), FIXED)

    def test_both_controls_precede_child_scope(self):
        for declaration in (recipe.RESET, recipe.SELECT):
            self.assertEqual(self.fixed.count(declaration), 1)
            self.assertLess(self.fixed.index(declaration), self.fixed.index(recipe.ANCHOR))

    def test_no_equation_or_sequential_change(self):
        # Only declaration location and two explanatory comment lines change.
        def remainder(text):
            return [line for line in text.splitlines()
                    if line.strip() and line + '\n' not in (recipe.RESET, recipe.SELECT)
                    and not line.startswith('// Declare shared controls before use')
                    and not line.startswith('// Vivado can infer undriven local wires')]
        self.assertEqual(remainder(self.parent), remainder(self.fixed))

    def test_drift_and_reapplication_rejected(self):
        for source in (self.parent + '\n', self.fixed, self.parent.replace('i8237', 'other')):
            with self.assertRaises(ValueError):
                recipe.transform(source)

    def test_partial_controls_still_leave_one_late_declaration(self):
        for reset, selector in ((False, True), (True, False)):
            source = recipe.transform(self.parent, reset=reset, selector=selector)
            self.assertNotEqual(source, self.fixed)
            for line, moved in ((recipe.RESET, reset), (recipe.SELECT, selector)):
                self.assertEqual(source.index(line) < source.index(recipe.ANCHOR), moved)

    def test_clean_overlay_applies_and_reverses_exactly(self):
        scratch = Path('/home/yukidama/external/tmp').resolve(strict=True)
        self.assertEqual(Path(os.environ['TMPDIR']).resolve(strict=True), scratch)
        marker = 'diff --git a/rtl/soc/dma.v b/rtl/soc/dma.v\n'
        overlay = OVERLAY.read_text()
        self.assertEqual(overlay.count(marker), 1)
        patch = marker + overlay.split(marker)[1].split('diff --git ', 1)[0]
        # Only this file's canonical hunk is under test; unrelated dirty overlay
        # sections are not promoted or asserted correct by this test.
        with tempfile.TemporaryDirectory(prefix='ventium-dma-overlay.', dir=scratch) as temp:
            root = Path(temp)
            dma = root / 'rtl/soc/dma.v'
            dma.parent.mkdir(parents=True)
            dma.write_text(self.base)
            def apply(*options):
                result = subprocess.run(['git', 'apply', *options, '-'], cwd=root,
                                        input=patch, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
            apply('--check')
            apply()
            self.assertEqual(dma.read_text(), self.fixed)
            apply('--reverse', '--check')
            apply('--reverse')
            self.assertEqual(dma.read_text(), self.base)

    def test_live_platform_matches_qualified_derivative(self):
        self.assertEqual((SUBMODULE / 'rtl/soc/dma.v').read_text(), self.fixed)


if __name__ == '__main__':
    unittest.main()
