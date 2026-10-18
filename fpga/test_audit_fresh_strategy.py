import unittest
from audit_fresh_strategy import audit_synth, audit_impl, audit_threads, property_value

SCRIPT = '''set_param general.maxThreads 1
set_property ip_cache_permissions disable [current_project]
synth_design -top rk_ao486_bd_wrapper -part xczu15eg-ffvb1156-2-i -directive PerformanceOptimized
'''
PROPS = '''AUTO_INCREMENTAL_CHECKPOINT bool false 0
INCREMENTAL_CHECKPOINT file false
STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY enum false rebuilt
STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE enum false PerformanceOptimized
STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING enum false auto
STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS string false
'''


class AuditTests(unittest.TestCase):
    def test_explicit_synthesis_retiming_requires_native_and_property_evidence(self):
        props = PROPS.replace('enum false auto', 'enum false on')
        script = SCRIPT.rstrip()+' -global_retiming on\n'
        audit_synth(script, props, 'performance-retime-bounded')
        for bad_script, bad_props in ((SCRIPT, props), (script, PROPS),
                (script.replace('retiming on', 'retiming off'), props),
                (script.rstrip()+' -global_retiming on\n', props),
                (SCRIPT.rstrip()+' -retiming\n', props)):
            with self.assertRaises(ValueError): audit_synth(bad_script, bad_props, 'performance-retime-bounded')
        with self.assertRaises(ValueError): audit_synth(script, props, 'performance-netdelay')

    def test_bounded_physical_commands_exclude_directives_and_repeated_passes(self):
        pre = '-fanout_opt -placement_opt -restruct_opt -equ_drivers_opt'
        post = '-placement_opt -routing_opt -restruct_opt -hold_fix'
        script = ('set_param general.maxThreads 1\nopt_design -directive RuntimeOptimized\n'
                  'place_design -directive AltSpreadLogic_medium\n'
                  f'phys_opt_design {pre}\nroute_design -directive NoTimingRelaxation\nphys_opt_design {post}\n')
        props = ''.join(f'STEPS.{step}.IS_ENABLED bool false 1\n'
                        f'STEPS.{step}.ARGS.DIRECTIVE enum false Default\n'
                        f'STEPS.{step}.ARGS.MORE OPTIONS string false {opts}\n'
                        for step, opts in (('PHYS_OPT_DESIGN', pre), ('POST_ROUTE_PHYS_OPT_DESIGN', post)))
        audit_impl(script, props, 'performance-retime-bounded')
        for bad in (script.replace(pre, '-directive Default '+pre), script+f'phys_opt_design {pre}\n',
                    script.replace('-hold_fix', ''), script.replace('NoTimingRelaxation', 'Default')):
            with self.assertRaises(ValueError): audit_impl(bad, props, 'performance-retime-bounded')
        for bad in (props.replace('Default', 'Explore'), props.replace('bool false 1', 'bool false 0'),
                    props.replace(pre, '-retime')):
            with self.assertRaises(ValueError): audit_impl(script, bad, 'performance-retime-bounded')

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
