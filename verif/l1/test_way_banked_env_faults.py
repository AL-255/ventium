"""Only model/source identities change; retain all 44 fixtures and grading."""
import unittest
import run_way_banked_env_faults as adapter


class Contract(unittest.TestCase):
    def test_native_run_and_grading_unchanged(self):
        text=adapter.derive();old=adapter.previous.derive()
        boundary='    cases = '
        self.assertEqual(text[text.index(boundary):],old[old.index(boundary):])
        self.assertIn("assert len(parent_files)==len(actual_files)==195 and parent_files.keys()==actual_files.keys()",text)
        self.assertIn('assert tags.transform(next_tag.transform(window.transform(',text)
        self.assertIn("assert fetch.transform((original/'candidate/rtl/core/core.sv').read_text())",text)
        self.assertIn("assert sha(model) == built['binary_sha256'] == '139e45dbd7a75a7ddffc19526387ab66bd01908908585aaae7f68c90059799b7'",text)


if __name__=='__main__':unittest.main()
