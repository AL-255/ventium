import unittest
from pathlib import Path
import prepare_load64_under_fill as recipe


class RecipeTest(unittest.TestCase):
    source = (Path(__file__).resolve().parents[2]/'rtl/mem/ven_l1d.sv').read_text()

    def test_changes_only_provenance_and_serve_context(self):
        result = recipe.transform(self.source)
        original = result.replace(recipe.OWNER+'\n'+recipe.CONTEXT, recipe.OWNER)
        original = original.replace('      load64_resident_context && hit &&\n      ((rd_full_line_q', recipe.SERVE)
        original = original.replace('rd_full_line_q <= load64_resident_context && hit && !fill_forward_hit && !stream_path &&', recipe.CAPTURE)
        self.assertEqual(original, self.source)

    def test_rejects_drift_and_double_application(self):
        for source in [recipe.transform(self.source), self.source.replace(recipe.SERVE, ''),
                       self.source + '\n' + recipe.CAPTURE]:
            with self.assertRaises(ValueError):
                recipe.transform(source)


if __name__ == '__main__':
    unittest.main()
