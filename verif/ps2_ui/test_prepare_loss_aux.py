"""Exact merge guards; the native iobus test supplies behavioral evidence."""
from pathlib import Path
import unittest
import prepare_loss_aux as recipe


class Recipe(unittest.TestCase):
    def test_exact_hunk_and_reject_changed_context(self):
        patch='--- a\n+++ b\n@@ -1,3 +1,3 @@\n a\n-b\n+B\n c\n'
        self.assertEqual(recipe.exact_patch('a\nb\nc\n',patch),'a\nB\nc\n')
        with self.assertRaises(ValueError): recipe.exact_patch('a\nx\nc\n',patch)
        with self.assertRaises(ValueError): recipe.exact_patch('a\nb\nc\n',patch.replace('+1,3','+1,2'))

    def test_current_aux_is_only_delta_from_retained_proposal(self):
        path=Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/v-result-carry-posted-mouse-fpga-r1/ventium/3rd-party/ao486_MiSTer/rtl/soc/ps2.v')
        old=path.read_text(); new=recipe.transform(old)
        self.assertEqual(recipe.digest(new),'9c9d62149a25a5e3f97683ca269b77d01dcf4034517c02a225a5bce0bd2dc405')
        self.assertEqual(recipe.digest(new.replace(recipe.AUX,recipe.OLD_AUX)),recipe.OLD_PROPOSAL)
        for invalid in (new,old+'\n',old.replace(recipe.AUX,recipe.OLD_AUX)):
            with self.subTest(digest=recipe.digest(invalid)), self.assertRaises(ValueError):
                recipe.transform(invalid)


if __name__=='__main__': unittest.main()
