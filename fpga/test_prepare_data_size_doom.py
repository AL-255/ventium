"""Keep the cold Doom probe scoped, passive and resource-bounded."""
import ast
from pathlib import Path
import unittest

import prepare_data_size_doom as recipe


class Recipe(unittest.TestCase):
    def test_identity_and_native_lifecycle(self):
        source = Path(recipe.__file__).with_name('run_endpoint_map_doom_smoke.py').read_text()
        text = recipe.transform(source); ast.parse(text)
        self.assertEqual(text.count('100000000'), 2)
        self.assertEqual(text.count('1800'), 2)
        self.assertIn("pc=Path(__file__).resolve().parents[1]/'soc-r1'", text)
        boundary = '    child=None;reason=None;failure=None;'
        self.assertEqual(text[text.index(boundary):], source[source.index(boundary):])
        for guard in ('child_reaped', "'--ven-fault-ring-events','16'", 'native.stable(pins)',
                      'guest_executable_and_wad_unchanged', 'resource.setrlimit',
                      "observed['affinity']==[12]", "(cgroup/'memory.swap.max')"):
            self.assertIn(guard, text)
        for forbidden in ('--snapshot-in', '--snapshot-out', '--break-eip', '--step'):
            self.assertNotIn(forbidden, text)
        for wrong in (source+'\n', text):
            with self.assertRaises(ValueError): recipe.transform(wrong)


if __name__ == '__main__': unittest.main()
