#!/usr/bin/env python3
"""Small host-only derivative-freeze tests; no Vivado or RTL simulation."""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HELPER = Path(__file__).with_name('freeze_rk_candidate.py')
SPEC = importlib.util.spec_from_file_location('freeze_rk_candidate', HELPER)
FREEZE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FREEZE)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class CandidateFreezeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ventium-rk-candidate-test-')
        self.addCleanup(self.temp.cleanup)
        # The helper deliberately rejects symlink ancestors. External scratch
        # is normally reached through ~/external, so use its canonical path;
        # otherwise negative tests could pass on the wrong preflight failure.
        self.root = Path(self.temp.name).resolve(strict=True)
        self.parent = self.root / 'parent'
        self.live = self.root / 'live'
        self.out = self.root / 'candidate'
        for path in (self.parent, self.live, self.out):
            path.mkdir()
        self.top = 'ventium/fp_shared/ven_fp_top.sv'
        names = [self.top, 'ventium/fpga/launch_impl_existing.tcl',
                 'ventium/fpga/board-tools/ven_board_probe.py']
        names += ['ventium/rtl/core/core.sv', 'ventium/rtl_ven_core.f']
        names += [f'ventium/rtl/file{i:03}.sv' for i in range(159)]
        names += [f'flow/hw/file{i:02}.tcl' for i in range(10)]
        names += ['template/board/XCZU15EG_Base_Config.tcl']
        names += ['evidence/compile-inputs.before.sha256', 'evidence/Vsystem__verFiles.dat',
                  'evidence/root-quake-closed-pass.json', 'evidence/root-win95-closed-pass.json']
        self.assertEqual(len(names), 179)
        records = []
        for name in names:
            path = self.parent / name
            path.parent.mkdir(parents=True, exist_ok=True)
            data = (json.dumps({'qualification': 'PASS', 'status': 'PASS', 'historical': name}) + '\n').encode()
            path.write_bytes(data)
            records.append({'source': '/historical/original/' + name, 'frozen': name,
                            'sha256': digest(path), 'bytes': len(data)})
        additions = ['SYNTHESIS', 'VTM_NO_DPI', 'VEN_ALTSYNCRAM_XPM']
        self.defs = [f'VEN_FIXTURE_{i:03}' for i in range(107)] + additions
        (self.parent / 'defines.txt').write_text('\n'.join(self.defs) + '\n')
        self.manifest = {'schema': 1, 'core_mhz': 40, 'simulator_defines': 107,
                         'hardware_additions': additions, 'hardware_defines': self.defs,
                         'model_profile': '5c2491f3', 'model_sha256': '5' * 64,
                         'qualification': 'PASS', 'profile_note': 'historical Win95/Quake PASS',
                         'files': records}
        self.save_manifest()
        self.source = self.live / 'ven_fp_top.sv'
        self.source.write_text('// explicit new source, not an accepted model\n')
        self.args = argparse.Namespace(parent=str(self.parent), out=str(self.out),
                                       parent_manifest_sha256=digest(self.parent / 'input-manifest.json'),
                                       parent_defines_sha256=digest(self.parent / 'defines.txt'),
                                       source_root=[str(self.live)],
                                       replace=[self.top + '=' + str(self.source)],
                                       replacement_sha256=[self.top + '=' + digest(self.source)])

    def save_manifest(self):
        (self.parent / 'input-manifest.json').write_text(json.dumps(self.manifest, indent=2) + '\n')

    def repin_manifest(self):
        self.save_manifest()
        self.args.parent_manifest_sha256 = digest(self.parent / 'input-manifest.json')

    def refused(self, args=None):
        with self.assertRaises((FREEZE.FreezeError, OSError, ValueError, TypeError, KeyError)):
            FREEZE.freeze(args or self.args)

    def test_179_shape_one_replacement_clear_current_acceptance(self):
        before = {r['frozen']: digest(self.parent / r['frozen']) for r in self.manifest['files']}
        parent_manifest_before = digest(self.parent / 'input-manifest.json')
        result = FREEZE.freeze(self.args)
        self.assertEqual((result['frozen_files'], result['unchanged_files'], result['replacement_files']),
                         (179, 178, 1))
        manifest = json.loads((self.out / 'input-manifest.json').read_text())
        receipt = json.loads((self.out / 'candidate-delta-manifest.json').read_text())
        self.assertEqual(manifest['qualification'], 'UNQUALIFIED')
        self.assertIsNone(manifest['model_profile'])
        self.assertIsNone(manifest['model_sha256'])
        self.assertIsNone(manifest['current_model_identity'])
        self.assertNotIn('current_acceptance', manifest)
        self.assertEqual(manifest['parent_ancestry']['qualification'], 'PASS')
        self.assertEqual(manifest['parent_ancestry']['model_sha256'], '5' * 64)
        self.assertEqual(manifest['core_mhz'], 40)
        self.assertEqual(manifest['hardware_defines'], self.defs)
        self.assertEqual((self.out / 'defines.txt').read_bytes(), (self.parent / 'defines.txt').read_bytes())
        self.assertEqual(result['manifest_sha256'], digest(self.out / 'input-manifest.json'))
        self.assertEqual(receipt['manifest_sha256'], result['manifest_sha256'])
        self.assertEqual(receipt['qualification'], 'UNQUALIFIED')
        self.assertEqual(len(manifest['files']), 179)
        for record in manifest['files']:
            name = record['frozen']
            expected = digest(self.source) if name == self.top else before[name]
            self.assertEqual(digest(self.out / name), expected)
            self.assertEqual(record['sha256'], expected)
            self.assertEqual(record['bytes'], (self.out / name).stat().st_size)
            parent_record = next(r for r in self.manifest['files'] if r['frozen'] == name)
            self.assertEqual(record['parent_sha256'], parent_record['sha256'])
            self.assertEqual(record['parent_bytes'], parent_record['bytes'])
            self.assertEqual(record['source'], str(self.source if name == self.top else self.parent / name))
            if name.startswith('evidence/'):
                self.assertEqual(record['role'], 'historical_ancestry_only')
        self.assertEqual(digest(self.parent / 'input-manifest.json'), parent_manifest_before)
        self.assertEqual(before, {r['frozen']: digest(self.parent / r['frozen']) for r in self.manifest['files']})

    def test_repeatable_two_explicit_replacements(self):
        name = 'ventium/rtl/file000.sv'
        source = self.live / 'second.sv'
        source.write_text('// second explicit replacement\n')
        self.args.replace.append(name + '=' + str(source))
        self.args.replacement_sha256.append(name + '=' + digest(source))
        result = FREEZE.freeze(self.args)
        self.assertEqual((result['unchanged_files'], result['replacement_files']), (177, 2))
        self.assertEqual((self.out / name).read_bytes(), source.read_bytes())

    def enable_fe(self):
        self.fe = self.live / 'ven_fe_dtlb.sv'
        self.fe.write_text('module ven_fe_dtlb; endmodule\n')
        self.core = self.live / 'core.sv'
        self.core.write_text('// explicit experimental parent integration\n')
        self.filelist = self.live / 'rtl_ven_core.f'
        self.filelist.write_text('rtl/core/ven_fe_dtlb.sv\nrtl/core/core.sv\n')
        for name, source in [('ventium/rtl/core/core.sv', self.core),
                             ('ventium/rtl_ven_core.f', self.filelist)]:
            self.args.replace.append(name + '=' + str(source))
            self.args.replacement_sha256.append(name + '=' + digest(source))
        self.args.fe_dtlb_source = str(self.fe)
        self.args.fe_dtlb_sha256 = digest(self.fe)

    def repin_filelist(self):
        self.args.replacement_sha256 = [
            'ventium/rtl_ven_core.f=' + digest(self.filelist)
            if item.startswith('ventium/rtl_ven_core.f=') else item
            for item in self.args.replacement_sha256]

    def test_fe_exact_bundle_unqualified_and_pinned(self):
        self.enable_fe()
        result = FREEZE.freeze(self.args)
        self.assertEqual((result['frozen_files'], result['unchanged_files'],
                          result['replacement_files'], result['added_files'], result['defines']),
                         (180, 176, 3, 1, 113))
        manifest = json.loads((self.out / 'input-manifest.json').read_text())
        receipt = json.loads((self.out / 'candidate-delta-manifest.json').read_text())
        defs = self.defs[:-3] + FREEZE.FE_DEFINES + self.defs[-3:]
        self.assertEqual(manifest['hardware_defines'], defs)
        self.assertEqual(manifest['simulator_defines'], 110)
        self.assertEqual(manifest['core_mhz'], 40)
        self.assertEqual(manifest['qualification'], 'UNQUALIFIED')
        self.assertIsNone(manifest['current_model_identity'])
        self.assertEqual((self.out / 'defines.txt').read_text().splitlines(), defs)
        self.assertEqual(result['defines_sha256'], digest(self.out / 'defines.txt'))
        added = next(r for r in manifest['files'] if r['frozen'] == FREEZE.FE_SOURCE)
        self.assertEqual(added['sha256'], digest(self.fe))
        self.assertIsNone(added['parent_sha256'])
        self.assertEqual(receipt['source_additions'], [added])
        self.assertEqual(receipt['added_defines'], FREEZE.FE_DEFINES)
        self.assertEqual((self.out / FREEZE.FE_SOURCE).read_bytes(), self.fe.read_bytes())
        self.assertFalse((self.parent / FREEZE.FE_SOURCE).exists())
        self.assertEqual((self.parent / 'defines.txt').read_text().splitlines(), self.defs)

    def test_fe_missing_source(self):
        self.enable_fe()
        self.args.fe_dtlb_source = None
        self.refused()

    def test_fe_missing_pin(self):
        self.enable_fe()
        self.args.fe_dtlb_sha256 = None
        self.refused()

    def test_fe_wrong_pin(self):
        self.enable_fe()
        self.args.fe_dtlb_sha256 = '0' * 64
        self.refused()

    def test_fe_requires_core_replacement(self):
        self.enable_fe()
        self.args.replace = [x for x in self.args.replace if not x.startswith('ventium/rtl/core/core.sv=')]
        self.args.replacement_sha256 = [x for x in self.args.replacement_sha256
                                        if not x.startswith('ventium/rtl/core/core.sv=')]
        self.refused()

    def test_fe_requires_filelist_replacement(self):
        self.enable_fe()
        self.args.replace = [x for x in self.args.replace if not x.startswith('ventium/rtl_ven_core.f=')]
        self.args.replacement_sha256 = [x for x in self.args.replacement_sha256
                                        if not x.startswith('ventium/rtl_ven_core.f=')]
        self.refused()

    def test_fe_missing_from_filelist(self):
        self.enable_fe()
        self.filelist.write_text('rtl/core/core.sv\n')
        self.repin_filelist()
        self.refused()

    def test_fe_duplicated_in_filelist(self):
        self.enable_fe()
        self.filelist.write_text('rtl/core/ven_fe_dtlb.sv\nrtl/core/ven_fe_dtlb.sv\nrtl/core/core.sv\n')
        self.repin_filelist()
        self.refused()

    def test_fe_after_core_in_filelist(self):
        self.enable_fe()
        self.filelist.write_text('rtl/core/core.sv\nrtl/core/ven_fe_dtlb.sv\n')
        self.repin_filelist()
        self.refused()

    def test_fe_outside_source_root(self):
        self.enable_fe()
        outside = self.root / 'outside.sv'
        outside.write_bytes(self.fe.read_bytes())
        self.args.fe_dtlb_source = str(outside)
        self.refused()

    def test_fe_symlink_source(self):
        self.enable_fe()
        alias = self.live / 'alias.sv'
        alias.symlink_to(self.fe)
        self.args.fe_dtlb_source = str(alias)
        self.refused()

    def test_fe_rejects_existing_defines_and_memory_chain(self):
        self.enable_fe()
        for name in FREEZE.FE_DEFINES + ['VEN_PIPE_MEM_CHAIN']:
            with self.subTest(name=name):
                self.manifest['hardware_defines'] = [name] + self.defs[1:]
                (self.parent / 'defines.txt').write_text('\n'.join(self.manifest['hardware_defines']) + '\n')
                self.args.parent_defines_sha256 = digest(self.parent / 'defines.txt')
                self.repin_manifest()
                self.refused()
                self.assertFalse(any(self.out.iterdir()))

    def test_fe_source_change_during_copy_prevents_manifest(self):
        self.enable_fe()
        original = FREEZE.write_new
        fired = False

        def changed(path, data):
            nonlocal fired
            result = original(path, data)
            if not fired:
                fired = True
                self.fe.write_text('late child change\n')
            return result

        with mock.patch.object(FREEZE, 'write_new', side_effect=changed):
            self.refused()
        self.assertFalse((self.out / 'input-manifest.json').exists())

    def test_parent_manifest_sha_alteration(self):
        (self.parent / 'input-manifest.json').write_bytes(b'{}\n')
        self.refused()

    def test_parent_payload_sha_alteration(self):
        (self.parent / 'ventium/rtl/file100.sv').write_text('changed\n')
        self.refused()
        self.assertFalse(any(self.out.iterdir()))

    def test_parent_payload_byte_count_alteration(self):
        self.manifest['files'][0]['bytes'] += 1
        self.repin_manifest()
        self.refused()

    def test_replacement_sha_alteration(self):
        self.source.write_text('source changed after explicit SHA pin\n')
        self.refused()
        self.assertFalse(any(self.out.iterdir()))

    def test_define_sha_alteration(self):
        (self.parent / 'defines.txt').write_text('VEN_OTHER\n')
        self.refused()

    def test_define_order_mismatch_even_when_repinned(self):
        defs = self.defs.copy()
        defs[0], defs[1] = defs[1], defs[0]
        (self.parent / 'defines.txt').write_text('\n'.join(defs) + '\n')
        self.args.parent_defines_sha256 = digest(self.parent / 'defines.txt')
        self.refused()

    def test_core_frequency_cannot_change(self):
        self.manifest['core_mhz'] = 50
        self.repin_manifest()
        self.refused()

    def test_parent_payload_symlink(self):
        path = self.parent / 'ventium/rtl/file100.sv'
        target = self.root / 'saved-parent-file'
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.refused()

    def test_parent_payload_fifo_refused_without_blocking(self):
        path = self.parent / 'ventium/rtl/file100.sv'
        path.unlink()
        os.mkfifo(path)
        self.refused()

    def test_parent_ancestor_directory_symlink(self):
        alias = self.root / 'parent-alias'
        alias.symlink_to(self.parent, target_is_directory=True)
        self.args.parent = str(alias)
        self.refused()

    def test_parent_manifest_symlink(self):
        path = self.parent / 'input-manifest.json'
        target = self.root / 'saved-manifest'
        target.write_bytes(path.read_bytes())
        path.unlink()
        path.symlink_to(target)
        self.refused()

    def test_replacement_symlink(self):
        target = self.live / 'real-source.sv'
        target.write_bytes(self.source.read_bytes())
        self.source.unlink()
        self.source.symlink_to(target)
        self.refused()

    def test_replacement_ancestor_symlink(self):
        alias = self.live / 'alias'
        alias.symlink_to(self.live, target_is_directory=True)
        self.args.replace = [self.top + '=' + str(alias / self.source.name)]
        self.refused()

    def test_output_symlink(self):
        alias = self.root / 'output-alias'
        alias.symlink_to(self.out, target_is_directory=True)
        self.args.out = str(alias)
        self.refused()

    def test_frozen_path_escape(self):
        self.manifest['files'][0]['frozen'] = '../outside.sv'
        self.repin_manifest()
        self.refused()

    def test_absolute_frozen_path(self):
        self.manifest['files'][0]['frozen'] = str(self.source)
        self.repin_manifest()
        self.refused()

    def test_noncanonical_frozen_path(self):
        self.manifest['files'][0]['frozen'] = 'ventium//fp_shared/ven_fp_top.sv'
        self.repin_manifest()
        self.refused()

    def test_duplicate_parent_path(self):
        self.manifest['files'][1] = copy.deepcopy(self.manifest['files'][0])
        self.repin_manifest()
        self.refused()

    def test_duplicate_replacement(self):
        self.args.replace *= 2
        self.refused()

    def test_duplicate_replacement_pin(self):
        self.args.replacement_sha256 *= 2
        self.refused()

    def test_unknown_replacement(self):
        name = 'ventium/rtl/not-in-parent.sv'
        self.args.replace = [name + '=' + str(self.source)]
        self.args.replacement_sha256 = [name + '=' + digest(self.source)]
        self.refused()

    def test_missing_replacement_pin(self):
        self.args.replacement_sha256 = []
        self.refused()

    def test_output_not_empty(self):
        (self.out / 'do-not-overwrite').write_text('already present\n')
        self.refused()
        self.assertEqual((self.out / 'do-not-overwrite').read_text(), 'already present\n')

    def test_output_inside_parent(self):
        nested = self.parent / 'output'
        nested.mkdir()
        self.args.out = str(nested)
        self.refused()

    def test_output_inside_source_root(self):
        nested = self.live / 'output'
        nested.mkdir()
        self.args.out = str(nested)
        self.refused()

    def test_double_slash_output_cannot_bypass_source_containment(self):
        nested = self.live / 'output'
        nested.mkdir()
        self.args.out = '/' + str(nested)
        self.refused()
        self.assertFalse(any(nested.iterdir()))

    def test_double_slash_source_root_is_not_canonical(self):
        self.args.source_root = ['/' + str(self.live)]
        self.refused()

    def test_output_ancestor_of_parent(self):
        self.args.out = str(self.root)
        self.refused()

    def test_replacement_outside_source_root(self):
        outside = self.root / 'outside.sv'
        outside.write_bytes(self.source.read_bytes())
        self.args.replace = [self.top + '=' + str(outside)]
        self.refused()

    def test_source_change_during_copy_prevents_manifest(self):
        original = FREEZE.write_new
        fired = False

        def changed(path, data):
            nonlocal fired
            result = original(path, data)
            if not fired:
                fired = True
                self.source.write_text('late source change\n')
            return result

        with mock.patch.object(FREEZE, 'write_new', side_effect=changed):
            self.refused()
        self.assertFalse((self.out / 'input-manifest.json').exists())

    def test_destination_change_during_copy_prevents_manifest(self):
        original = FREEZE.write_new
        first = None

        def changed(path, data):
            nonlocal first
            result = original(path, data)
            if first is None:
                first = path
            elif path.name == 'defines.txt':
                first.write_text('late copied-file change\n')
            return result

        with mock.patch.object(FREEZE, 'write_new', side_effect=changed):
            self.refused()
        self.assertFalse((self.out / 'input-manifest.json').exists())

    def test_same_bytes_source_inode_replacement_prevents_manifest(self):
        original = FREEZE.write_new
        fired = False

        def changed(path, data):
            nonlocal fired
            result = original(path, data)
            if not fired:
                fired = True
                replacement = self.live / 'moved.sv'
                replacement.write_bytes(self.source.read_bytes())
                replacement.replace(self.source)
            return result

        with mock.patch.object(FREEZE, 'write_new', side_effect=changed):
            self.refused()
        self.assertFalse((self.out / 'input-manifest.json').exists())

    def test_cli_refuses_current_model_or_pass_acceptance_claims(self):
        base = [sys.executable, '-B', str(HELPER), '--parent', self.args.parent,
                '--parent-manifest-sha256', self.args.parent_manifest_sha256,
                '--parent-defines-sha256', self.args.parent_defines_sha256,
                '--source-root', self.args.source_root[0], '--replace', self.args.replace[0],
                '--replacement-sha256', self.args.replacement_sha256[0], '--out', self.args.out]
        for claim in (['--qualification', 'PASS'], ['--current-model-sha256', 'a' * 64]):
            with self.subTest(claim=claim):
                run = subprocess.run(base + claim, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(run.returncode, 0)
                self.assertFalse(any(self.out.iterdir()))


if __name__ == '__main__':
    unittest.main()
