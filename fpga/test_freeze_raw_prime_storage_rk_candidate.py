import unittest

import freeze_raw_prime_storage_rk_candidate as export
from freeze_rk_candidate import FreezeError


class Export(unittest.TestCase):
    def test_all_parent_payloads_only_three_changes(self):
        parent = export.native.ROOT/'sfetch-boundary-fpga-r1'
        soc = export.native.ROOT/'raw-prime-storage-soc-r1'
        manifest = export.native.load(parent/'input-manifest.json')
        changed = []
        for row in manifest['files']:
            name = row['frozen']; before = (parent/name).read_bytes(); after = before
            self.assertEqual(export.sha256(before), row['sha256'])
            if name.startswith('ventium/') and export.Path(name).suffix in export.base.SUFFIXES:
                after = (soc/'source'/name.removeprefix('ventium/')).read_bytes()
                if name == export.base.SYSTEM: after = export.base.projection(before,after)
            if name == export.INJECTOR: after = export.mmio.template.FIXED.read_bytes()
            if export.check_delta(name,before,after): changed.append(name)
        self.assertEqual(len(manifest['files']),192)
        self.assertEqual(sorted(changed),export.CHANGES)

    def test_unrelated_changes_and_missing_repairs_rejected(self):
        parent = export.native.ROOT/'sfetch-boundary-fpga-r1'
        for name in export.CHANGES:
            before = (parent/name).read_bytes()
            with self.subTest(name=name), self.assertRaises((AssertionError,FreezeError)):
                export.check_delta(name,before,before)
        with self.assertRaises(FreezeError):
            export.check_delta('flow/src/ven_mgmt_axil.v',b'old',b'new')

    def test_exact_profile_and_failed_acceptance_retained(self):
        root = export.native.ROOT
        old = export.native.load(root/'sfetch-boundary-fpga-r1/input-manifest.json')
        start = export.native.load(root/'raw-prime-storage-soc-r1/build-started.json')
        closed = export.native.load(root/'raw-prime-storage-soc-r1/build-closed.json')
        defs = (root/'raw-prime-storage-soc-r1/defines.txt').read_text().splitlines()
        export.check_profile(old,start,closed,defs)
        for target,key,bad in ((old,'core_mhz',70),(old,'write_slots',8),
                               (start,'parent_model','wrong'),(start,'canonical_gate_passed',True),
                               (start,'legacy_aggregate_gate_passed',True),(start,'changes',[]),
                               (closed,'native_exit',1),(closed,'binary_sha256','wrong')):
            saved = target[key]; target[key] = bad
            try:
                with self.subTest(key=key), self.assertRaises(FreezeError):
                    export.check_profile(old,start,closed,defs)
            finally: target[key] = saved
        with self.assertRaises((AssertionError,FreezeError)):
            export.check_profile(old,start,closed,defs+['PAIR_OFF'])


if __name__ == '__main__': unittest.main()
