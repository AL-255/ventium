"""Execute the real cache-key shell equations; no fake architectural traces."""
import os
from pathlib import Path
import subprocess
import unittest

import prepare_observer_cache_key as recipe

SOURCE = Path(__file__).with_name('verify_worker.sh')


class CacheKeyTests(unittest.TestCase):
    def test_exact_reversible_scope(self):
        old = SOURCE.read_text(); new = recipe.transform(old)
        for before, after in reversed(recipe.CHANGES):
            self.assertEqual(new.count(after), 1)
            new = new.replace(after, before)
        self.assertEqual(new, old)
        with self.assertRaises(ValueError): recipe.transform(old+'\n')
        with self.assertRaises(ValueError): recipe.transform(recipe.transform(old))

    def key(self, value, candidate=True):
        text = recipe.transform(SOURCE.read_text()) if candidate else SOURCE.read_text()
        start = text.index('SRC_SHA=')
        stop = text.index('# =============================================================================', start)
        shell = 'set -eu\n'+text[start:stop]+'\nprintf "%s\\n" "$ORACLE_SIG"\n'
        env = dict(os.environ, SRC=str(SOURCE), ELF=str(SOURCE), QEMU=str(SOURCE),
                   P5TRACE=str(SOURCE), CC='gcc', CFLAGS_BASE='test flags', LOAD='0x0', ENTRY='0x0')
        env.pop('VTM_QEMU_GDB_PREEXIT', None)
        if value is not None: env['VTM_QEMU_GDB_PREEXIT'] = value
        return subprocess.check_output(['bash', '-c', shell], env=env, text=True).strip()

    def test_observer_semantics(self):
        disabled = self.key(None)
        self.assertNotEqual(disabled, self.key('1'))
        for value in ('', '0', 'true', '01', '1\n', '2'):
            self.assertEqual(disabled, self.key(value))
        self.assertEqual(self.key('0', False), self.key('1', False))
        self.assertNotEqual(self.key('0', False), disabled)  # old cache deliberately invalidated

    def test_cycle_looks_up_exact_func_key(self):
        text = recipe.transform(SOURCE.read_text())
        func = next(s for s in text.splitlines() if s.strip().startswith('KEY=') and '.func.' in s)
        lookup = next(s for s in text.splitlines() if s.startswith('FUNC_GOLD='))
        env = dict(os.environ, SRC_SHA='source', ELF_SHA='0123456789abcdef',
                   ORACLE_SIG='fedcba9876543210', X87='1', MAX='22', CACHE_DIR='/test-cache')
        command = func+'\n'+lookup+'\nprintf "%s\\n%s\\n" "$CACHE_DIR/$KEY.vtrace" "$FUNC_GOLD"'
        paths = subprocess.check_output(['bash', '-c', command], env=env, text=True).splitlines()
        self.assertEqual(paths[0], paths[1])


if __name__ == '__main__': unittest.main()
