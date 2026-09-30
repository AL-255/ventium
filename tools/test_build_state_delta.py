#!/usr/bin/env python3
"""Bounded host-only tests; never elaborate, compile or launch a guest model."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_state_delta as subject


def generated_makefile(target='ao486sim_ven_standard'):
    return ('# Verilated -*- Makefile -*-\n'
            f'default: {target}\n\n'
            'sim_ven.o: sim_ven.cpp \n'
            '\t$(CXX) -c -o $@ $<\n\n'
            f'{target}: $(VK_USER_OBJS) $(VK_GLOBAL_OBJS) $(VM_PREFIX)__ALL.a\n'
            '\t$(LINK) $(LDFLAGS) $^ $(LOADLIBES) $(LDLIBS) '
            '$(LIBS) $(SC_LIBS) -o $@\n')


class TargetTests(unittest.TestCase):
    def test_legacy_and_standard(self):
        for target in sorted(subject.EXECUTABLES):
            with self.subTest(target=target):
                self.assertEqual(subject.executable_target(generated_makefile(target)), target)

    def test_reject_bad_or_missing_default(self):
        valid = generated_makefile()
        bad = [valid.replace('default:', 'no_default:'),
               valid + '\ndefault: ao486sim_ven\n']
        for target in ('other', '../ao486sim_ven', '/tmp/ao486sim_ven',
                       'ao486sim_ven ao486sim_ven_standard',
                       '$(shell touch /tmp/injected)', 'ao486sim_ven; echo injected',
                       'ao486sim_ven # comment', 'ao486sim_ven\\'):
            bad.append(valid.replace('default: ao486sim_ven_standard', f'default: {target}'))
        for makefile in bad:
            with self.subTest(makefile=makefile):
                with self.assertRaises(ValueError):
                    subject.executable_target(makefile)

    def test_reject_missing_duplicate_or_injected_link_rule(self):
        valid = generated_makefile()
        for makefile in (valid.replace('ao486sim_ven_standard:', 'other:'),
                         valid + valid.split('\n\n')[-1],
                         valid.replace(' -o $@', ' -o /tmp/other'),
                         valid + '\techo injected\n',
                         valid + '\n# hidden extra recipe\n\techo injected\n',
                         valid.replace('$(VK_USER_OBJS)', '$(shell echo injected)')):
            with self.subTest(makefile=makefile):
                with self.assertRaises(ValueError):
                    subject.executable_target(makefile)


class ModelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ventium-state-relink-test.')
        self.addCleanup(self.temp.cleanup)
        self.obj = Path(self.temp.name) / 'obj_dir_copy'
        self.obj.mkdir()
        self.make_model()

    def make_model(self, target='ao486sim_ven_standard'):
        (self.obj/'Vsystem.mk').write_text(generated_makefile(target))
        for name in ('Vsystem__ALL.a', 'Vsystem___024root.h',
                     'Vsystem___024root__Slow.cpp', 'Vsystem__Syms.h',
                     'sim_ven.cpp', 'sim_ven.o', target):
            (self.obj/name).write_text('host-only fixture ' + name + '\n')

    def assert_prelaunch_failure(self, obj=None):
        with patch.object(subject, 'generate') as generate, \
             patch.object(subject, 'inherited_lock_fds') as fds, \
             patch.object(subject.subprocess, 'run') as run:
            with self.assertRaises((ValueError, OSError)):
                subject.relink(obj or self.obj)
            generate.assert_not_called()
            fds.assert_not_called()
            run.assert_not_called()

    def test_normal_commands_and_result_preserve_legacy(self):
        for target in sorted(subject.EXECUTABLES):
            with self.subTest(target=target):
                self.make_model(target)
                def fake_rebuild(command, **_kwargs):
                    if command[0] == 'make':
                        (self.obj/'sim_ven.o').write_text('rebuilt host object\n')
                        (self.obj/target).write_text('relinked host executable\n')
                with patch.object(subject, 'generate') as generate, \
                     patch.object(subject, 'inherited_lock_fds', return_value=(71, 72)), \
                     patch.object(subject.subprocess, 'run', side_effect=fake_rebuild) as run:
                    subject.relink(self.obj)
                    generate.assert_called_once_with(self.obj)
                    self.assertEqual(run.call_count, 2)
                    guard, make = run.call_args_list
                    self.assertEqual(guard.args[0][-1], '--is-active')
                    self.assertEqual(guard.kwargs['pass_fds'], (71, 72))
                    self.assertEqual(guard.kwargs['timeout'], 10)
                    self.assertEqual(make.args[0][-1], target)
                    self.assertEqual(make.kwargs['pass_fds'], (71, 72))
                    self.assertIn('-j1', make.args[0])
                    self.assertEqual(make.args[0][make.args[0].index('-W') + 1],
                                     'sim_ven.cpp')
                receipt = json.loads((self.obj/'ven_state_relink.json').read_text())
                self.assertTrue(receipt['model_unchanged'])
                self.assertTrue(receipt['host_object_rebuilt'])
                self.assertTrue(receipt['executable_relinked'])
                self.assertEqual(receipt['executable'], target)
                self.assertEqual(receipt['profiler_sha256'], subject.digest(self.obj/target))

    def test_bad_target_fails_before_mutation(self):
        (self.obj/'Vsystem.mk').write_text(generated_makefile('../unsafe'))
        self.assert_prelaunch_failure()

    def test_missing_binary_or_archive_fails_before_mutation(self):
        for name in ('ao486sim_ven_standard', 'Vsystem__ALL.a', 'sim_ven.o'):
            with self.subTest(name=name):
                path = self.obj/name
                saved = path.read_bytes()
                path.unlink()
                self.assert_prelaunch_failure()
                path.write_bytes(saved)

    def test_missing_or_injected_host_dependency(self):
        path = self.obj/'sim_ven.cpp'
        path.unlink()
        self.assert_prelaunch_failure()
        path.write_text('stub\n')
        (self.obj/'Vsystem.mk').write_text(generated_makefile().replace(
            'sim_ven.o: sim_ven.cpp', 'sim_ven.o: sim_ven.cpp; echo injected'))
        self.assert_prelaunch_failure()

    def test_reject_object_directory_and_ancestor_symlinks(self):
        alias = Path(self.temp.name)/'obj_dir_alias'
        alias.symlink_to(self.obj, target_is_directory=True)
        self.assert_prelaunch_failure(alias)
        parent_alias = Path(self.temp.name)/'parent_alias'
        parent_alias.symlink_to(Path(self.temp.name), target_is_directory=True)
        self.assert_prelaunch_failure(parent_alias/self.obj.name)

    def test_reject_symlinked_output_artifacts(self):
        external = Path(self.temp.name)/'external'
        external.write_text('preserve\n')
        for name in ('ao486sim_ven_standard', 'ven_state_fields.inc',
                     'ven_state_fields.audit.json', 'ven_state_relink.json',
                     'sim_ven.o', 'sim_ven.d'):
            with self.subTest(name=name):
                path = self.obj/name
                saved = path.read_bytes() if path.exists() else None
                if path.exists():
                    path.unlink()
                path.symlink_to(external)
                self.assert_prelaunch_failure()
                path.unlink()
                if saved is not None:
                    path.write_bytes(saved)
                self.assertEqual(external.read_text(), 'preserve\n')

    def test_reject_directory_or_hardlinked_outputs(self):
        path = self.obj/'ven_state_fields.inc'
        path.mkdir()
        self.assert_prelaunch_failure()
        path.rmdir()
        external = Path(self.temp.name)/'external'
        external.write_text('preserve\n')
        os.link(external, path)
        self.assert_prelaunch_failure()
        path.unlink()
        binary = self.obj/'ao486sim_ven_standard'
        binary.unlink()
        os.link(external, binary)
        self.assert_prelaunch_failure()

    def test_unresolved_vpath_spelling_uses_actual_dependency(self):
        source = self.obj/'sim_ven.cpp'
        (self.obj/'Vsystem.mk').write_text(generated_makefile().replace(
            'sim_ven.o: sim_ven.cpp', 'sim_ven.o: nonexistent/sim_ven.cpp'))
        (self.obj/'sim_ven.d').write_text('sim_ven.o: ' + str(source) + '\n')
        _, _, _, command = subject.prepare_relink(self.obj)
        self.assertEqual(command[command.index('-W') + 1], str(source))

    def test_unchanged_object_or_executable_rejects_false_success(self):
        for rebuild_object in (False, True):
            with self.subTest(rebuild_object=rebuild_object):
                def maybe_rebuild(command, **_kwargs):
                    if command[0] == 'make' and rebuild_object:
                        (self.obj/'sim_ven.o').write_text('host object only\n')
                with patch.object(subject, 'inherited_lock_fds', return_value=(73,)), \
                     patch.object(subject, 'generate'), \
                     patch.object(subject.subprocess, 'run', side_effect=maybe_rebuild):
                    expected = 'executable was not relinked' if rebuild_object else 'host object was not rebuilt'
                    with self.assertRaisesRegex(RuntimeError, expected):
                        subject.relink(self.obj)
                self.assertFalse((self.obj/'ven_state_relink.json').exists())

    def test_actual_gnu_make_relative_dependency_on_copied_tree(self):
        # Reproduce the integration graph, not just a mocked command:
        # an unresolved VPATH rule plus a different, existing relative .d
        # prerequisite. Recipes only touch two host fixture files, never C++
        # compilation, generated RTL, a simulator or the real build lock.
        source_dir = Path(self.temp.name)/'src'
        source_dir.mkdir()
        source = source_dir/'sim_ven.cpp'
        source.write_text('int host_fixture;\n')
        (self.obj/'sim_ven.cpp').unlink()
        makefile = generated_makefile().replace(
            'sim_ven.o: sim_ven.cpp', 'sim_ven.o: src/sim_ven.cpp').replace(
            '\t$(CXX) -c -o $@ $<', '\ttouch $@')
        makefile = ('VK_USER_OBJS = sim_ven.o\nVK_GLOBAL_OBJS =\nVM_PREFIX = Vsystem\n'
                    + makefile +
                    '\nLINK = python3 fake_link.py\nVPATH = ..\ninclude sim_ven.d\n')
        (self.obj/'Vsystem.mk').write_text(makefile)
        (self.obj/'sim_ven.d').write_text('sim_ven.o: ../src/sim_ven.cpp\n')
        (self.obj/'fake_link.py').write_text(
            'import pathlib,sys\npathlib.Path(sys.argv[-1]).touch()\n')
        # Pre-existing object/executable are newer than their sources; only
        # a correctly spelled -W can cause their recipes to execute.
        os.utime(source, ns=(1_000_000_000, 1_000_000_000))
        original_object = subject.file_identity(self.obj/'sim_ven.o')
        original_binary = subject.file_identity(self.obj/'ao486sim_ven_standard')
        copied = Path(self.temp.name)/'obj_dir_copied'
        shutil.copytree(self.obj, copied)
        _, target, _, command = subject.prepare_relink(copied)
        index = command.index('-W') + 1
        self.assertEqual(command[index], '../src/sim_ven.cpp')
        wrong = command.copy()
        wrong[index] = str(source.resolve())
        real_run = subprocess.run
        before_object = subject.file_identity(copied/'sim_ven.o')
        before_binary = subject.file_identity(copied/target)
        wrong_result = real_run(wrong, capture_output=True, timeout=2)
        self.assertEqual(wrong_result.returncode, 0, wrong_result.stderr)
        self.assertEqual(before_object, subject.file_identity(copied/'sim_ven.o'))
        self.assertEqual(before_binary, subject.file_identity(copied/target))
        def guard_or_make(argv, **kwargs):
            if argv[0] != 'make':
                return subprocess.CompletedProcess(argv, 0)
            return real_run(argv, **kwargs, capture_output=True, timeout=2)
        lock_file = copied/'host_fixture.lock'
        with lock_file.open('w+') as lock:
            with patch.object(subject, 'inherited_lock_fds', return_value=(lock.fileno(),)), \
                 patch.object(subject, 'generate'), \
                 patch.object(subject.subprocess, 'run', side_effect=guard_or_make):
                subject.relink(copied)
                first = json.loads((copied/'ven_state_relink.json').read_text())
                subject.relink(copied)  # already-enabled repeat still rebuilds
                second = json.loads((copied/'ven_state_relink.json').read_text())
        self.assertNotEqual(first['host_object_before'], first['host_object_after'])
        self.assertNotEqual(first['executable_before'], first['executable_after'])
        self.assertEqual(second['host_object_before'], first['host_object_after'])
        self.assertEqual(second['executable_before'], first['executable_after'])
        self.assertNotEqual(second['host_object_before'], second['host_object_after'])
        self.assertNotEqual(second['executable_before'], second['executable_after'])
        self.assertEqual(subject.digest(self.obj/'Vsystem__ALL.a'),
                         subject.digest(copied/'Vsystem__ALL.a'))
        self.assertEqual(original_object, subject.file_identity(self.obj/'sim_ven.o'))
        self.assertEqual(original_binary, subject.file_identity(self.obj/target))

    def test_absent_lock_or_failed_scope_does_not_generate(self):
        for outcome in (ValueError('no lock'), (73,)):
            with self.subTest(outcome=outcome):
                kwargs = {'side_effect': outcome} if isinstance(outcome, Exception) else {'return_value': outcome}
                with patch.object(subject, 'inherited_lock_fds', **kwargs), \
                     patch.object(subject, 'generate') as generate, \
                     patch.object(subject.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'guard')):
                    with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                        subject.relink(self.obj)
                    generate.assert_not_called()

    def test_model_hash_change_rejected_without_success_receipt(self):
        def mutate(command, **_kwargs):
            if command[0] == 'make':
                (self.obj/'Vsystem__ALL.a').write_text('changed model\n')
        with patch.object(subject, 'inherited_lock_fds', return_value=(73,)), \
             patch.object(subject, 'generate'), \
             patch.object(subject.subprocess, 'run', side_effect=mutate):
            with self.assertRaisesRegex(RuntimeError, 'model changed'):
                subject.relink(self.obj)
        self.assertFalse((self.obj/'ven_state_relink.json').exists())


class LockTests(unittest.TestCase):
    def test_real_inherited_lock_not_fixed_to_nine(self):
        with tempfile.TemporaryDirectory(prefix='ventium-state-lock-test.') as directory:
            path = Path(directory)/'lock'
            with path.open('w+') as stream:
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                fd = fcntl.fcntl(stream.fileno(), fcntl.F_DUPFD, 70)
                try:
                    result = subject.inherited_lock_fds(path)
                    self.assertIn(fd, result)
                    self.assertIn(stream.fileno(), result)
                    self.assertNotIn(9, result)
                    # A plain host child proves that pass_fds really retains
                    # a discovered nonstandard descriptor; no build is invoked.
                    proc = subprocess.run(['python3', '-c',
                                           'import os,sys; os.fstat(int(sys.argv[1]))', str(fd)],
                                          pass_fds=result, timeout=2, check=True)
                    self.assertEqual(proc.returncode, 0)
                finally:
                    os.close(fd)

    def test_missing_closed_and_conflicting_descriptors_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix='ventium-state-lock-test.') as directory:
            path = Path(directory)/'lock'
            with self.assertRaises(ValueError):
                subject.inherited_lock_fds(path)
            path.write_text('')
            with self.assertRaises(ValueError):
                subject.inherited_lock_fds(path)
            with path.open('r+'):
                with patch.object(subject.fcntl, 'flock', side_effect=BlockingIOError):
                    with self.assertRaises(ValueError):
                        subject.inherited_lock_fds(path)


if __name__ == '__main__':
    unittest.main()
