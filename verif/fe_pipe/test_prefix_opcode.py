import os
from pathlib import Path
import subprocess
import unittest

import prepare_prefix_opcode as recipe


class PrefixOpcodeTests(unittest.TestCase):
    def test_exact_delta_and_drift(self):
        source = (Path(os.environ['PREFIX_OPCODE_PARENT']) / recipe.FILE).read_text()
        new = recipe.transform(source)
        self.assertEqual(new.replace(recipe.NEW, ''), source.replace(recipe.OLD, ''))
        for changed in (source + '\n', new):
            with self.assertRaises(ValueError):
                recipe.transform(changed)

    def test_unconstrained_two_state_identity(self):
        for mutant, expected in ((False, 'unsat'), (True, 'sat')):
            result = subprocess.run(['/usr/bin/z3', '-in'], input=recipe.identity_smt(mutant),
                                    text=True, capture_output=True, check=True, timeout=20)
            self.assertEqual(result.stdout.strip(), expected)
            self.assertEqual(result.stderr, '')


if __name__ == '__main__':
    unittest.main()
