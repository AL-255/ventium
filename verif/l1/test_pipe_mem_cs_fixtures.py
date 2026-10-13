"""Audit assembled CS-limit images and prove the layout checker rejects drift."""
import json
import os
from pathlib import Path
import unittest

from prepare_pipe_mem_cs_fixtures import CASES, audit_image, expected, sha


class PipeCSFixtures(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(os.environ['PIPE_CS_FIXTURES']).resolve(strict=True)
        cls.closed = json.loads((cls.root/'closed.json').read_text())
        cls.started = json.loads((cls.root/'started.json').read_text())
        assert all(sha(p) == h for p, h in cls.started['pins'].items())

    def rows(self):
        for row in self.closed['cases']:
            want = row['expected']
            case = tuple(want[k] for k in ('kind', 'length', 'over'))
            image = Path(row['image']).read_bytes()
            self.assertEqual(sha(row['image']), row['image_sha256'])
            yield case, image, row['symbols'], want

    def test_all_twelve_native_layouts(self):
        self.assertEqual(len(self.closed['cases']), 12)
        self.assertEqual({case for case, *_ in self.rows()}, set(CASES))
        for case, image, symbols, want in self.rows():
            with self.subTest(case=case):
                self.assertEqual(audit_image(image, symbols, case), want)
                self.assertEqual(want['fault_pc'], 0x8030 if case[2] else 0x8030+case[1])
                self.assertEqual(want['cs_limit'] < 0x8030+case[1]-1, bool(case[2]))

    def test_opcode_branch_descriptor_and_fail_door_mutants(self):
        for case, image, symbols, _ in self.rows():
            # Mutants corrupt independently checked linked locations.
            start = symbols['probe_template']-0xf0000
            probe = symbols['probe_insn']-0xf0000
            descriptor = image.index(bytes.fromhex('66c7061c05009a4000'))
            for address in (start+32, probe, descriptor+5, probe+case[1]+5, 0xfff0):
                with self.subTest(case=case, address=address):
                    changed = bytearray(image)
                    changed[address] ^= 1
                    with self.assertRaises(AssertionError):
                        audit_image(changed, symbols, case)

    def test_bad_configuration_rejected(self):
        for case in ((-1, 2, 0), (2, 2, 0), (0, 4, 0), (0, 2, 2)):
            with self.assertRaises(ValueError):
                expected(*case)

    def test_preparation_does_not_claim_execution(self):
        self.assertFalse(self.closed['core_executed'])
        self.assertFalse(self.closed['hardware_acceptance'])
        self.assertFalse(self.closed['standard_suite'])
        self.assertIsNone(self.closed['gameplay_ipc'])
        self.assertTrue(all(not row['executed'] for row in self.closed['cases']))


if __name__ == '__main__':
    unittest.main()
