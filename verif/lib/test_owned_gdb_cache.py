"""Execute actual worker identity equations, without fabricated .vtrace data."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import prepare_owned_gdb_cache as recipe

WORKER = Path(__file__).with_name('verify_worker.sh')


class Checks(unittest.TestCase):
    def test_exact_scope(self):
        new = WORKER.read_text()
        old = recipe.original(new)
        self.assertEqual(recipe.transform(old), new)
        subprocess.run(['bash', '-n'], input=new, text=True, check=True)
        key = 'KEY="${SRC_SHA}.${ELF_SHA:0:12}.${ORACLE_SIG:0:12}.cycle"'
        self.assertEqual(new.count(key), old.count(key))
        self.assertEqual(new.count(key), 1)
        with self.assertRaises(ValueError):
            recipe.original(new+'\n')

    def test_all_dependencies_invalidate_only_functional_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gen = root/'qemu-trace'; gen.mkdir()
            diff = root/'diff'; diff.mkdir()
            paths = [gen/'gen_trace.py', gen/'owned_gdb.py', diff/'tracefmt.py']
            for path in paths: path.write_text('original\n')
            text = WORKER.read_text()
            func = next(line for line in text.splitlines()
                        if line.strip().startswith('KEY=') and '.func.' in line)
            lookup = next(line for line in text.splitlines() if line.startswith('FUNC_GOLD='))
            cycle = next(line for line in text.splitlines()
                         if line.startswith('KEY=') and '.cycle' in line)
            shell = '''set -eu
_sha_of() { sha1sum "$1" | cut -d' ' -f1; }
SRC_SHA=source ELF_SHA=0123456789abcdef ORACLE_SIG=abcdef0123456789
X87=1 MAX=64 CACHE_DIR=/cache PREEXIT_MODE=1
''' + recipe.IDENTITY + func + '\n' + lookup + '''
printf '%s\\n%s\\n' "$KEY" "$FUNC_GOLD"
''' + cycle + '\nprintf "%s\\n" "$KEY"\n'
            def keys():
                return subprocess.check_output(['bash'], input=shell, text=True,
                    env=dict(os.environ, GEN_TRACE=str(paths[0]))).splitlines()
            baseline = keys()
            self.assertEqual(baseline[1], '/cache/'+baseline[0]+'.vtrace')
            for path in paths:
                path.write_text('modified\n')
                changed = keys()
                self.assertNotEqual(changed[0], baseline[0], path)
                self.assertEqual(changed[1], '/cache/'+changed[0]+'.vtrace')
                self.assertEqual(changed[2], baseline[2])
                path.write_text('original\n')
            self.assertEqual(keys(), baseline)


if __name__ == '__main__':
    unittest.main()
