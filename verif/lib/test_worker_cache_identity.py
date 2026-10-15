"""Exact-scope and shell-policy tests; native tests are separate."""
from pathlib import Path
import subprocess
import unittest

import prepare_worker_cache_identity as recipe

WORKER = Path(__file__).with_name('verify_worker.sh')


class Checks(unittest.TestCase):
    def setUp(self):
        text = WORKER.read_text()
        self.old = recipe.original(text) if recipe.NEW_LOOKUP in text else text
        self.new = recipe.transform(self.old)

    def test_exact_scope_and_shell_syntax(self):
        self.assertEqual(recipe.original(self.new), self.old)
        subprocess.run(['bash', '-n'], input=self.new, text=True, check=True)
        cycle_key = 'KEY="${SRC_SHA}.${ELF_SHA:0:12}.${ORACLE_SIG:0:12}.cycle"'
        self.assertEqual(self.old.count(cycle_key), 1)
        self.assertEqual(self.new.count(cycle_key), 1)

    def test_drift_and_partial_repair_rejected(self):
        for text in (self.old + '\n', self.new, self.old.replace(recipe.OLD_LOOKUP, ''),
                     self.old.replace('GOLDEN_FMT="v2"', 'GOLDEN_FMT="v3"')):
            with self.assertRaises(ValueError):
                recipe.transform(text)
        with self.assertRaises(ValueError):
            recipe.original(self.new.replace(recipe.NEW_LOOKUP, recipe.OLD_LOOKUP))

    def test_functional_key_and_lookup_are_identical(self):
        functional = recipe.preexit.NEW
        lookup = recipe.NEW_LOOKUP
        for mode in ('', '0', '1', '01', 'yes'):
            script = '''SRC_SHA=source ELF_SHA=123456789012abc ORACLE_SIG=abc123456789abc
X87=1 MAX=300 CACHE_DIR=/cache
''' + functional + '\n' + lookup + '\nprintf "%s\\n%s\\n" "$KEY" "$FUNC_GOLD"\n'
            import os
            result = subprocess.check_output(['bash'], input=script, text=True,
                env=dict(os.environ, VTM_QEMU_GDB_PREEXIT=mode)).splitlines()
            self.assertEqual(result[1], '/cache/' + result[0] + '.vtrace')
            self.assertIn('.preexit' + str(int(mode == '1')) + '.', result[0])


if __name__ == '__main__':
    unittest.main()
