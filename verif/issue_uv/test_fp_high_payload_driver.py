"""Preserve all original x87/system and whole-cycle grading in the new profile."""
import importlib.util
import inspect
from pathlib import Path
import unittest
import test_fp_load_payload_driver as parent

spec=importlib.util.spec_from_file_location('fp_high_payload_driver',
    Path(__file__).with_name('run-fp-high-payload-ab.py'))
driver=importlib.util.module_from_spec(spec)
spec.loader.exec_module(driver)


class HighNativeX87Closure(parent.LoadNativeX87Closure):
    def grade(self, trace=None, err=None, exit_code=133):
        return driver.grade_fp_native(self.trace if trace is None else trace,'',
            self.err if err is None else err,exit_code,133,100)

    def test_original_grader_is_byte_identical(self):
        self.assertEqual(inspect.getsource(driver.grade_fp_native),
                         inspect.getsource(parent.driver.grade_fp_native))

    def test_only_profile_contract_changes(self):
        old=Path(parent.driver.__file__).read_text()
        expected=old.replace('Whole-core FP load payload selection:',
                             'Whole-core FP high-word transport:').replace(
            "added = {'VEN_FP_LOAD_PAYLOAD_SELECT'}",
            "added = {'VEN_FP_LOAD64_PAYLOAD_SELECT'}").replace(
            "assert {'VEN_FP_PIPE_PAYLOAD_SELECT', 'VEN_SRT_PAYLOAD_SELECT'} <= profiles['control']",
            "assert {'VEN_FP_PIPE_PAYLOAD_SELECT', 'VEN_SRT_PAYLOAD_SELECT', 'VEN_FP_LOAD_PAYLOAD_SELECT', 'VEN_FP_LOAD64'} <= profiles['control']")
        self.assertEqual(Path(driver.__file__).read_text().rstrip(),expected.rstrip())


if __name__=='__main__':
    unittest.main()
