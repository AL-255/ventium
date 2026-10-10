"""SRT runner retains the full architectural closure grader and fixture."""
import importlib.util
from pathlib import Path
import unittest

import test_fp_payload_driver as parent

source = Path(__file__).with_name('run-srt-payload-ab.py')
spec = importlib.util.spec_from_file_location('srt_payload_driver', source)
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class SrtNativeX87Closure(parent.NativeX87Closure):
    def grade(self, trace=None, err=None, exit_code=133):
        return driver.grade_fp_native(self.trace if trace is None else trace, '',
            self.err if err is None else err, exit_code, 133, 100)

    def test_only_profile_delta_from_checked_runner(self):
        reference = source.with_name('run-fp-payload-ab.py').read_text()
        expected = reference.replace('Whole-core FP payload selection:',
                                     'Whole-core SRT payload selection:')
        expected = expected.replace("added = {'VEN_FP_PIPE_PAYLOAD_SELECT'}",
            "added = {'VEN_SRT_PAYLOAD_SELECT'}\n"
            "    assert 'VEN_FP_PIPE_PAYLOAD_SELECT' in profiles['control']")
        self.assertEqual(source.read_text(), expected)


if __name__ == '__main__':
    unittest.main()
