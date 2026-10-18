"""Project-view ordering/failure checks; the native fixture is separate."""
from pathlib import Path
import subprocess
import unittest


class EvidenceTests(unittest.TestCase):
    def test_only_completed_current_synthesis_is_opened_and_always_closed(self):
        helper = Path(__file__).with_name('fresh_synth_evidence.tcl').read_text()
        for case, expected, opened, closed in (
                ('pass', 0, 1, 1), ('failed_synth', 1, 0, 0), ('failed_report', 1, 1, 1)):
            script = '''
set opened 0
set closed 0
set fresh_script_dir /expected
proc get_runs {r} {
 if {$r ne "synth_1"} {error "wrong run"}
 return $r
}
proc get_property {p r} {
 if {$p ne "STATUS" || $r ne "synth_1"} {error "unexpected property"}
 if {$::case eq "failed_synth"} {return "synth_design ERROR"}
 return "synth_design Complete!"
}
proc open_run {r} {
 if {$r ne "synth_1"} {error "wrong run"}
 incr ::opened
}
proc close_design {} {incr ::closed}
proc source {p} {
 if {$p ne "/expected/fresh_synth_post.tcl"} {error "wrong evidence script"}
 if {$::case eq "failed_report"} {error "no clocks"}
}
'''+f'\nset case {case}\n'+helper+f'''
set code [catch {{fresh_synth_evidence}} message]
if {{$code != {expected} || $opened != {opened} || $closed != {closed}}} {{
 puts stderr "unexpected code=$code open=$opened close=$closed message=$message"
 exit 1
}}
puts EVIDENCE-ORDER-OK
'''
            result = subprocess.run(['tclsh'], input=script, text=True, capture_output=True)
            with self.subTest(case=case):
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
                self.assertIn('EVIDENCE-ORDER-OK', result.stdout)


if __name__ == '__main__': unittest.main()
