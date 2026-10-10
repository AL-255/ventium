"""Keep full x87/system closure checks in the extended boundary runner."""
import importlib.util
import inspect
from pathlib import Path
import unittest

import test_fp_payload_driver as parent

spec = importlib.util.spec_from_file_location('fp_load_payload_driver',
    Path(__file__).with_name('run-fp-load-payload-ab.py'))
driver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class LoadNativeX87Closure(parent.NativeX87Closure):
    def grade(self, trace=None, err=None, exit_code=133):
        return driver.grade_fp_native(self.trace if trace is None else trace, '',
            self.err if err is None else err, exit_code, 133, 100)

    def test_original_grader_is_byte_identical(self):
        self.assertEqual(inspect.getsource(driver.grade_fp_native),
                         inspect.getsource(parent.driver.grade_fp_native))


if __name__ == '__main__':
    unittest.main()
