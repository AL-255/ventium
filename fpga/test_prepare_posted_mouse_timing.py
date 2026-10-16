"""No CAD launched: exercise controller derivation and native Tcl admission."""
import os
from pathlib import Path
import subprocess
import unittest

import prepare_posted_mouse_timing as prep


class Controllers(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = {n: (prep.ROOT/n).read_text() for n in prep.TEMPLATES}
        for name, digest in prep.TEMPLATES.items():
            assert prep.sha(prep.ROOT/name) == digest, name
        cls.output = prep.derive(cls.original)

    def test_lifetimes_and_admission_unchanged(self):
        for target, parent in ((prep.SYNTH, 'v-result-carry-synthesis-r3'),
                               (prep.CLOCK, 'v-result-carry-clock-r1')):
            new, old = self.output[target+'/run.py'], self.original[parent+'/run.py']
            boundary = 'owner = None\n'
            self.assertEqual(new[new.index(boundary):], old[old.index(boundary):])
            begin, end = 'host = available()\n', "(root/'once').mkdir()"
            self.assertEqual(new[new.index(begin):new.index(end)], old[old.index(begin):old.index(end)])

    def test_source_identity_does_not_promote_lint_or_suite(self):
        for target in (prep.SYNTH, prep.CLOCK):
            text = self.output[target+'/run.py']
            self.assertIn("source = root.parent/'"+prep.SOURCE+"'", text)
            self.assertIn("lint['source_manifest_sha256'] == '"+prep.evidence.repair.PARENT_SHA+"'", text)
            self.assertIn('pins.update(mouse_evidence.check(source))', text)
            self.assertIn("not freeze['full_wrapper_elaborated']", text)
            self.assertIn("not verify['canonical_gate_passed']" if target == prep.SYNTH
                          else "assert json.loads((synthesis/'audit.json').read_text())['passed']", text)
        clock = self.output[prep.CLOCK+'/run.py']
        self.assertIn("assert manifest_sha == '"+prep.evidence.MANIFEST+"'", clock)
        self.assertNotIn("source = root.parent/'v-result-carry-fpga-r1'", clock)
        self.assertEqual(self.output[prep.CLOCK+'/audit.tcl'],
                         self.original['v-result-carry-clock-r1/audit.tcl'])

    def test_native_source_audit_retained_and_strengthened(self):
        text = self.output[prep.SYNTH+'/audit_closed.py']
        self.assertIn('assert str(source/name) in native_pins, name', text)
        self.assertIn('MOUSE_POSTED_PREFLIGHT_OK exact_sources=3', text)
        self.assertIn("for module in ('ven_ps2_mailbox','ven_ps2_device')", text)
        self.assertIn('ps2_mousedat_dev).*does not have driver', text)
        self.assertIn(prep.evidence.WRAPPER_SHA, text)

    def test_anchor_drift_rejected(self):
        originals = dict(self.original)
        originals['v-result-carry-clock-r1/run.py'] = originals['v-result-carry-clock-r1/run.py'].replace(
            "freeze['source_contract_passed']", "freeze['something_else']")
        with self.assertRaises(AssertionError):
            prep.derive(originals)


class TclAdmission(unittest.TestCase):
    def run_case(self, scenario):
        # Stubs are deliberate: prove guard behavior, not Vivado API semantics.
        script = r'''
proc launch_runs {run args} {puts "NATIVE_LAUNCH $run $args"}
proc update_compile_order {args} {
    if {$args ne "-fileset sources_1"} {error "unexpected update arguments"}
}
proc get_files {args} {
    if {$args ne "-compile_order sources -used_in synthesis"} {error "unexpected get_files arguments"}
    set result {}
    foreach name {rk_ao486_system_pl.v ven_ps2_device.sv ven_ps2_mailbox.sv} {
        lappend result [file join $::env(VEN_FPGA_FLOW_ROOT) src $name]
    }
    switch $::env(TEST_SCENARIO) {
        missing {set result [lrange $result 0 1]}
        duplicate {lappend result [lindex $result 2]}
        wrong_path {lset result 2 /wrong/ven_ps2_mailbox.sv}
    }
    return $result
}
proc get_property {property object} {
    if {$property ne "NAME"} {error "unexpected property"}
    return $object
}
rename source native_source
proc source {path} {
    if {$path ne [file join $::env(VEN_FPGA_SOURCE_ROOT) fpga create_project_3mhz_wrapper.tcl]} {
        error "unexpected flow source"
    }
    switch $::env(TEST_SCENARIO) {
        impl {launch_runs impl_1 -jobs 1}
        no_launch {return}
        default {
            launch_runs synth_1 -jobs 1
            if {$::env(TEST_SCENARIO) eq "twice"} {launch_runs synth_1 -jobs 1}
        }
    }
}
if {[catch {native_source $::env(TEST_GUARD)} message]} {
    puts stderr $message
    exit 1
}
exit 0
'''
        env = dict(os.environ, TEST_SCENARIO=scenario,
                   TEST_GUARD=str(Path(__file__).with_name('launch_posted_mouse_checked.tcl').resolve()),
                   VEN_FPGA_SOURCE_ROOT='/home/yukidama/external/tmp/unused-source',
                   VEN_FPGA_FLOW_ROOT='/home/yukidama/external/tmp/unused-flow')
        return subprocess.run(['tclsh'], input=script, env=env, text=True,
                              capture_output=True, timeout=5)

    def test_single_launch_passes(self):
        result = self.run_case('valid')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count('NATIVE_LAUNCH synth_1 -jobs 1'), 1)
        self.assertEqual(result.stdout.count('MOUSE_POSTED_PREFLIGHT_SOURCE '), 3)

    def test_missing_duplicate_wrong_path_rejected_before_launch(self):
        for case in ('missing', 'duplicate', 'wrong_path'):
            with self.subTest(case=case):
                result = self.run_case(case)
                self.assertEqual(result.returncode, 1)
                self.assertIn('mouse source absent/duplicated', result.stderr)
                self.assertNotIn('NATIVE_LAUNCH', result.stdout)

    def test_impl_and_second_launch_rejected(self):
        for case, expected_launches in (('impl', 0), ('twice', 1)):
            with self.subTest(case=case):
                result = self.run_case(case)
                self.assertEqual(result.returncode, 1)
                self.assertIn('only one synthesis launch', result.stderr)
                self.assertEqual(result.stdout.count('NATIVE_LAUNCH'), expected_launches)

    def test_missing_launch_rejected(self):
        result = self.run_case('no_launch')
        self.assertEqual(result.returncode, 1)
        self.assertIn('expected one guarded synthesis launch', result.stderr)


if __name__ == '__main__':
    unittest.main()
