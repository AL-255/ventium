"""Source identity and local selection proof; not a whole-core substitute."""
from itertools import product
from pathlib import Path
import re
import unittest
import prepare_decode_bus_payload as recipe

SOURCE = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4/strict-mf-core-r1/candidate')/recipe.FILE


def selection(text, translate, decode):
    guard = re.search(r'if \((.*?)\) bd_addr = cur_lin;', text)[1]
    expression = guard.replace('state == S_DECODE', 'decode').replace('fe_translatable', 'translate').replace('||', 'or')
    return eval(expression, {'__builtins__': {}}, dict(translate=translate, decode=decode))


class DecodeBusPayload(unittest.TestCase):
    def test_exact_payload_only_delta(self):
        original = SOURCE.read_text()
        changed = recipe.transform(original)
        self.assertEqual(changed.replace(recipe.NEW, recipe.OLD), original)
        self.assertEqual(changed.count(recipe.NEW), 1)
        for bad in (changed, original+'\n'):
            with self.assertRaises(ValueError): recipe.transform(bad)

    def test_authorized_beat_and_probe_selection(self):
        changes = 0
        for translate, decode, request in product((False, True), repeat=3):
            old = selection(recipe.OLD, translate, decode)
            new = selection(recipe.NEW, translate, decode)
            # Local assumption is an existing clocked whole-core assertion,
            # not a newly relaxed transaction contract.
            if decode and request: continue
            if request or translate: self.assertEqual(old, new)
            if old != new:
                self.assertTrue(decode and not request and not translate)
                changes += 1
        self.assertEqual(changes, 1)
        self.assertTrue(selection(recipe.NEW, False, True))
        self.assertTrue(selection(recipe.NEW, True, True))
        # The unfixed selector retains a late dependency even in DECODE.
        self.assertNotEqual(selection(recipe.OLD, False, True), selection(recipe.OLD, True, True))


if __name__ == '__main__':
    unittest.main()
