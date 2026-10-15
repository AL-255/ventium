"""Flatten identity adapters without launching their benchmark payload."""
import ast
import builtins
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parent


def flattened(name):
    namespace={'__file__':str(ROOT/name),'__name__':'adapter_test'}
    def capture(code,scope):
        # Each adapter ends in exec(compile(text,...),globals()). Only expand
        # adapters; never execute the final argparse/native runner or auditor.
        text=scope['text']
        if "exec(compile(text" in text:
            builtins.exec(code,scope)
        else:
            scope['flattened']=text
    namespace['exec']=capture
    builtins.exec(compile((ROOT/name).read_text(),name,'exec'),namespace)
    return namespace['flattened']


class IdentityOnly(unittest.TestCase):
    def test_runner_only_owner_and_pin_addition(self):
        parent=flattened('run_pair_next_disjoint_coremark.py')
        new=flattened('run_fetch_metadata_coremark.py')
        expected=parent.replace('ventium-pair-next-disjoint-cm10-','ventium-fetch-metadata-cm10-')
        expected=expected.replace('original,original_driver,Path(native_observation.__file__)',
                                  'original,original_driver,original_adapter,Path(native_observation.__file__)')
        self.assertEqual(new,expected)
        ast.parse(new)

    def test_audit_only_model_and_pin_addition(self):
        parent=flattened('audit_pair_next_disjoint_coremark.py')
        new=flattened('audit_fetch_metadata_coremark.py')
        expected=parent.replace('b542e94d172defa3528ef0e2faf80a636a5072aa99e63d6ab6ff56335acba2a2',
                                'e09cd8f84ad449a445c13af01a4c15f47852fc7c26cff63f7792ce8e780ae503')
        expected=expected.replace('original,original_driver,Path(__file__)',
                                  'original,original_driver,original_adapter,Path(__file__)')
        self.assertEqual(new,expected)
        ast.parse(new)


if __name__=='__main__':unittest.main()
