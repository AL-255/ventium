import argparse
from pathlib import Path
import unittest
import prepare


class Prepare(unittest.TestCase):
    def test_exact(self):
        new = prepare.transform(SOURCE)
        self.assertEqual(new.replace(prepare.FUNCTION, '').replace(prepare.NEW, prepare.OLD), SOURCE)
        self.assertEqual(new.count('always_ff'), SOURCE.count('always_ff'))
        self.assertEqual(prepare.compare_block(new).replace(prepare.NEW, prepare.OLD),
                         prepare.compare_block(SOURCE))

    def test_drift(self):
        for bad in (SOURCE+'\n', prepare.transform(SOURCE)):
            with self.assertRaises(ValueError): prepare.transform(bad)


if __name__ == '__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--source',type=Path,required=True)
    args,remaining=parser.parse_known_args()
    SOURCE=args.source.read_text()
    unittest.main(argv=['test_prepare',*remaining])
