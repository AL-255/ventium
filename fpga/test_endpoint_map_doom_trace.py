import ast
from pathlib import Path
import unittest

from prepare_endpoint_map_doom_trace import transform


class TraceRecipe(unittest.TestCase):
    def test_observation_only(self):
        source = Path(__file__).with_name('run_endpoint_map_doom_smoke.py').read_text()
        text = transform(source)
        ast.parse(text)
        self.assertIn("'--cycles','34000000'",text)
        self.assertIn('time.monotonic()-start>900',text)
        self.assertIn("'--ven-fault-ring-events','8'",text)
        self.assertIn("'--ven-state-cycles','20000'",text)
        self.assertIn("'--vtm-dump','40000'",text)
        for disallowed in ('--restore','--save-at','--ven-break-eip','--ven-break-retire'):
            self.assertNotIn(disallowed,text)
        for guard in ('4*1024**3','512*1024**2','signal.SIGTERM','signal.SIGKILL',
                      'native.stable(pins)','guest_executable_and_wad_unchanged'):
            self.assertIn(guard,text)

    def test_drift_and_reapplication_rejected(self):
        source = Path(__file__).with_name('run_endpoint_map_doom_smoke.py').read_text()
        for changed in (source+'\n',transform(source)):
            with self.assertRaises(ValueError): transform(changed)


if __name__ == '__main__': unittest.main()
