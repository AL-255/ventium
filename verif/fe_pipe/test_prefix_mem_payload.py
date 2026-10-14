import os
from pathlib import Path
import subprocess
import unittest

import prepare_prefix_mem_payload as recipe


class PrefixPayloadTests(unittest.TestCase):
    def setUp(self):
        root = Path(os.environ['PREFIX_PAYLOAD_PARENT'])
        self.source = (root/recipe.FILE).read_text()
        self.decoder = (root/recipe.DECODER_FILE).read_text()

    def test_only_field_overrides(self):
        out = recipe.transform(self.source, self.decoder)
        self.assertEqual(out.replace(recipe.suffix(), ''), self.source)
        self.assertEqual(len(recipe.GUARDED + recipe.METADATA), 19)
        self.assertEqual(len(set(recipe.GUARDED + recipe.METADATA)), 19)
        self.assertNotIn('p54_prefix66_candidate', recipe.suffix())

    def test_drift_and_reapplication(self):
        for source, decoder in ((self.source+'\n', self.decoder),
                                (self.source, self.decoder+'\n'),
                                (recipe.transform(self.source, self.decoder), self.decoder)):
            with self.assertRaises(ValueError):
                recipe.transform(source, decoder)

    def test_guarded_flag_cofactor_and_negative_control(self):
        for mutant, expected in ((False, 'unsat'), (True, 'sat')):
            result = subprocess.run(['/usr/bin/z3', '-in'],
                input=recipe.flag_identity_smt(mutant), text=True, capture_output=True,
                timeout=5, check=True)
            self.assertEqual(result.stdout.strip(), expected)
            self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
