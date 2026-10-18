import unittest
from audit_fresh_strategy import audit_synth, audit_threads, property_value

SCRIPT = '''set_param general.maxThreads 1
set_property ip_cache_permissions disable [current_project]
synth_design -top rk_ao486_bd_wrapper -part xczu15eg-ffvb1156-2-i -directive PerformanceOptimized
'''
PROPS = '''AUTO_INCREMENTAL_CHECKPOINT bool false 0
INCREMENTAL_CHECKPOINT file false
STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY enum false rebuilt
STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE enum false PerformanceOptimized
STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS string false
'''


class AuditTests(unittest.TestCase):
    def test_internal_thread_cap_is_explicit_and_unique(self):
        for threads in (1, 2):
            script = SCRIPT.replace('maxThreads 1', f'maxThreads {threads}')
            self.assertEqual(audit_synth(script, PROPS, 'performance-netdelay', threads)['configured_threads'], threads)
            for bad in (script+f'set_param general.maxThreads {threads}\n',
                        script.replace(f'maxThreads {threads}', 'maxThreads 8'),
                        script.replace('set_param general.maxThreads', '#set_param general.maxThreads')):
                with self.assertRaises(ValueError): audit_threads(bad, threads)
        with self.assertRaises(ValueError): audit_threads(SCRIPT, 2)
        for unsupported in (0, 3, 8, True, '1', None):
            with self.assertRaises(ValueError): audit_threads(SCRIPT, unsupported)

    def test_omitted_native_default_needs_actual_property(self):
        self.assertTrue(audit_synth(SCRIPT, PROPS, 'performance-netdelay')['hierarchy_default_omitted'])
        explicit = SCRIPT.rstrip()+' -flatten_hierarchy rebuilt\n'
        self.assertFalse(audit_synth(explicit, PROPS, 'performance-netdelay')['hierarchy_default_omitted'])
        for props in (PROPS.replace('rebuilt', 'none'), PROPS.replace('rebuilt', ''),
                      '\n'.join(r for r in PROPS.splitlines() if 'FLATTEN_HIERARCHY' not in r)):
            with self.assertRaises(ValueError): audit_synth(SCRIPT, props, 'performance-netdelay')

    def test_no_incremental_cache_or_timing_disable(self):
        for script in (SCRIPT+'read_checkpoint /old/run.dcp\n',
                       SCRIPT.replace('disable', '{read write}'), SCRIPT.replace('maxThreads 1', 'maxThreads 4'),
                       SCRIPT.rstrip()+' -no_timing_driven\n', SCRIPT.rstrip()+' -incremental\n',
                       SCRIPT.rstrip()+' -flatten_hierarchy none\n'):
            with self.assertRaises(ValueError): audit_synth(script, PROPS, 'performance-netdelay')
        for props in (PROPS.replace('bool false 0', 'bool false 1'),
                      PROPS.replace('file false', 'file false /old/run.dcp'),
                      PROPS.replace('string false', 'string false -no_timing_driven')):
            with self.assertRaises(ValueError): audit_synth(SCRIPT, props, 'performance-netdelay')

    def test_blank_property_does_not_consume_next_line(self):
        self.assertEqual(property_value(PROPS, 'INCREMENTAL_CHECKPOINT'), '')
        with self.assertRaises(ValueError): property_value(PROPS+PROPS, 'INCREMENTAL_CHECKPOINT')


if __name__ == '__main__': unittest.main()
