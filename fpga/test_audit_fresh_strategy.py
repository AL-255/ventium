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
    def test_retiming_route_first_changes_only_retiming_and_keeps_phys_disabled(self):
        strategy = 'routability-retime-route-first'
        props = PROPS.replace('PerformanceOptimized', 'AlternateRoutability').replace('enum false auto', 'enum false on')
        properties = ''.join(f'STEPS.{step}.IS_ENABLED bool false 0\n'
                            f'STEPS.{step}.ARGS.DIRECTIVE enum false Default\n'
                            f'STEPS.{step}.ARGS.MORE OPTIONS string false\n'
                            for step in ('PHYS_OPT_DESIGN', 'POST_ROUTE_PHYS_OPT_DESIGN'))
        for synth_threads, apr_threads in ((1, 4), (8, 8)):
            with self.subTest(synth=synth_threads, apr=apr_threads):
                script = SCRIPT.replace('maxThreads 1', f'maxThreads {synth_threads}').replace('PerformanceOptimized', 'AlternateRoutability').rstrip()+' -global_retiming on\n'
                result = audit_synth(script, props, strategy, synth_threads)
                self.assertEqual(result['properties']['STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING'], 'on')
                for bad in (script.replace('retiming on', 'retiming off'),
                            script.replace('retiming on', 'retiming auto'),
                            script.replace(' -global_retiming on', ''),
                            script.rstrip()+' -global_retiming on\n',
                            script.replace('AlternateRoutability', 'PerformanceOptimized'),
                            script+'read_checkpoint old.dcp\n',
                            script+'set_param general.maxThreads 1\n'):
                    with self.assertRaises(ValueError): audit_synth(bad, props, strategy, synth_threads)
                for bad in (props.replace('enum false on', 'enum false off'),
                            props.replace('enum false on', 'enum false auto'),
                            props.replace('AlternateRoutability', 'PerformanceOptimized')):
                    with self.assertRaises(ValueError): audit_synth(script, bad, strategy, synth_threads)
                impl = (f'set_param general.maxThreads {apr_threads}\nopt_design -directive RuntimeOptimized\n'
                        'place_design -directive AltSpreadLogic_high\nroute_design -directive AlternateCLBRouting\n')
                self.assertEqual(audit_impl(impl, properties, strategy, apr_threads)['physical_operations'], [])
                for bad in (impl+'phys_opt_design\n', impl+'phys_opt_design -retime\n',
                            impl.replace('AltSpreadLogic_high', 'AltSpreadLogic_medium'),
                            impl.replace('AlternateCLBRouting', 'NoTimingRelaxation'),
                            impl.replace(f'maxThreads {apr_threads}', 'maxThreads 2')):
                    with self.assertRaises(ValueError): audit_impl(bad, properties, strategy, apr_threads)
                for bad in (properties.replace('bool false 0', 'bool false 1'),
                            properties.replace('Default', 'Explore'),
                            properties.replace('string false', 'string false -retime')):
                    with self.assertRaises(ValueError): audit_impl(impl, bad, strategy, apr_threads)
        with self.assertRaises(ValueError):
            audit_synth(script.replace('maxThreads 8', 'maxThreads 2'), props, strategy, 2)

    def test_parallel8_requires_exact_native_counts_and_unchanged_directives(self):
        for strategy, directive, place, route in (
                ('performance-route-first', 'PerformanceOptimized', 'AltSpreadLogic_medium', 'NoTimingRelaxation'),
                ('routability-route-first', 'AlternateRoutability', 'AltSpreadLogic_high', 'AlternateCLBRouting')):
            script = SCRIPT.replace('maxThreads 1', 'maxThreads 8').replace('PerformanceOptimized', directive).rstrip()+' -global_retiming off\n'
            props = PROPS.replace('PerformanceOptimized', directive).replace('enum false auto', 'enum false off')
            self.assertEqual(audit_synth(script, props, strategy, 8)['configured_threads'], 8)
            for bad in (script.replace('maxThreads 8', 'maxThreads 1'),
                        script+'set_param general.maxThreads 8\n', script+'read_checkpoint old.dcp\n'):
                with self.assertRaises(ValueError): audit_synth(bad, props, strategy, 8)
            impl = (f'set_param general.maxThreads 8\nopt_design -directive RuntimeOptimized\n'
                    f'place_design -directive {place}\nroute_design -directive {route}\n')
            properties = ''.join(f'STEPS.{step}.IS_ENABLED bool false 0\n'
                                f'STEPS.{step}.ARGS.DIRECTIVE enum false Default\n'
                                f'STEPS.{step}.ARGS.MORE OPTIONS string false\n'
                                for step in ('PHYS_OPT_DESIGN', 'POST_ROUTE_PHYS_OPT_DESIGN'))
            self.assertEqual(audit_impl(impl, properties, strategy, 8)['physical_operations'], [])
            for bad in (impl.replace('maxThreads 8', 'maxThreads 4'), impl+'phys_opt_design\n'):
                with self.assertRaises(ValueError): audit_impl(bad, properties, strategy, 8)
        with self.assertRaises(ValueError): audit_threads(SCRIPT, 8)

    def test_congestion_route_first_requires_exact_new_directives(self):
        strategy = 'routability-route-first'
        script = SCRIPT.replace('PerformanceOptimized', 'AlternateRoutability').rstrip()+' -global_retiming off\n'
        props = PROPS.replace('PerformanceOptimized', 'AlternateRoutability').replace('enum false auto', 'enum false off')
        audit_synth(script, props, strategy, 1)
        for bad in (script.replace('AlternateRoutability', 'PerformanceOptimized'),
                    script.replace(' -global_retiming off', ''), script+'read_checkpoint old.dcp\n'):
            with self.assertRaises(ValueError): audit_synth(bad, props, strategy, 1)
        impl = ('set_param general.maxThreads 4\nopt_design -directive RuntimeOptimized\n'
                'place_design -directive AltSpreadLogic_high\nroute_design -directive AlternateCLBRouting\n')
        properties = ''.join(f'STEPS.{step}.IS_ENABLED bool false 0\n'
                            f'STEPS.{step}.ARGS.DIRECTIVE enum false Default\n'
                            f'STEPS.{step}.ARGS.MORE OPTIONS string false\n'
                            for step in ('PHYS_OPT_DESIGN', 'POST_ROUTE_PHYS_OPT_DESIGN'))
        self.assertEqual(audit_impl(impl, properties, strategy, 4)['physical_operations'], [])
        for bad in (impl.replace('AltSpreadLogic_high', 'AltSpreadLogic_medium'),
                    impl.replace('AlternateCLBRouting', 'NoTimingRelaxation'), impl+'phys_opt_design\n'):
            with self.assertRaises(ValueError): audit_impl(bad, properties, strategy, 4)
        for count in (1, 2):
            with self.assertRaises(ValueError): audit_impl(impl, properties, strategy, count)
        with self.assertRaises(ValueError): audit_impl(impl, properties.replace('bool false 0', 'bool false 1'), strategy, 4)

    def test_route_first_requires_serial_synth_apr4_and_zero_optional_phys(self):
        props = PROPS.replace('enum false auto', 'enum false off')
        script = SCRIPT.rstrip()+' -global_retiming off\n'
        audit_synth(script, props, 'performance-route-first', 1)
        for threads in (2, 4):
            with self.assertRaises(ValueError):
                audit_synth(script.replace('maxThreads 1', f'maxThreads {threads}'), props, 'performance-route-first', threads)
        impl = ('set_param general.maxThreads 4\nopt_design -directive RuntimeOptimized\n'
                'place_design -directive AltSpreadLogic_medium\nroute_design -directive NoTimingRelaxation\n')
        properties = ''.join(f'STEPS.{step}.IS_ENABLED bool false 0\n'
                            f'STEPS.{step}.ARGS.DIRECTIVE enum false Default\n'
                            f'STEPS.{step}.ARGS.MORE OPTIONS string false\n'
                            for step in ('PHYS_OPT_DESIGN', 'POST_ROUTE_PHYS_OPT_DESIGN'))
        self.assertEqual(audit_impl(impl, properties, 'performance-route-first', 4)['physical_operations'], [])
        for bad in (impl+'phys_opt_design\n', impl+'phys_opt_design', impl+' phys_opt_design -directive Explore\n',
                    impl.replace('NoTimingRelaxation', 'Default'), impl.replace('maxThreads 4', 'maxThreads 1')):
            with self.assertRaises(ValueError): audit_impl(bad, properties, 'performance-route-first', 4)
        for bad in (properties.replace('bool false 0', 'bool false 1'),
                    properties.replace('Default', 'Explore'), properties.replace('string false', 'string false -hold_fix')):
            with self.assertRaises(ValueError): audit_impl(impl, bad, 'performance-route-first', 4)
        with self.assertRaises(ValueError): audit_impl(impl, properties, 'performance-bounded', 4)
        with self.assertRaises(ValueError): audit_synth(SCRIPT.replace('maxThreads 1', 'maxThreads 4'), PROPS, 'performance-netdelay', 4)

    def test_retiming_disabled_strategy_requires_explicit_off_evidence(self):
        props = PROPS.replace('enum false auto', 'enum false off')
        script = SCRIPT.rstrip()+' -global_retiming off\n'
        audit_synth(script, props, 'performance-bounded')
        for bad_script, bad_props in ((SCRIPT, props), (script, PROPS),
                (script.replace('retiming off', 'retiming on'), props),
                (script.rstrip()+' -global_retiming off\n', props),
                (SCRIPT.rstrip()+' -no_retiming\n', props)):
            with self.assertRaises(ValueError): audit_synth(bad_script, bad_props, 'performance-bounded')
        with self.assertRaises(ValueError): audit_synth(script, props, 'performance-retime-bounded')

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
        for strategy in ('performance-retime-bounded', 'performance-bounded'):
            audit_impl(script, props, strategy)
            for bad in (script.replace(pre, '-directive Default '+pre), script+f'phys_opt_design {pre}\n',
                        script.replace('-hold_fix', ''), script.replace('NoTimingRelaxation', 'Default')):
                with self.assertRaises(ValueError): audit_impl(bad, props, strategy)
            for bad in (props.replace('Default', 'Explore'), props.replace('bool false 1', 'bool false 0'),
                        props.replace(pre, '-retime')):
                with self.assertRaises(ValueError): audit_impl(script, bad, strategy)

    def test_internal_thread_cap_is_explicit_and_unique(self):
        for threads in (1, 2):
            script = SCRIPT.replace('maxThreads 1', f'maxThreads {threads}')
            self.assertEqual(audit_synth(script, PROPS, 'performance-netdelay', threads)['configured_threads'], threads)
            for bad in (script+f'set_param general.maxThreads {threads}\n',
                        script.replace(f'maxThreads {threads}', 'maxThreads 8'),
                        script.replace('set_param general.maxThreads', '#set_param general.maxThreads')):
                with self.assertRaises(ValueError): audit_threads(bad, threads)
        with self.assertRaises(ValueError): audit_threads(SCRIPT, 2)
        for unsupported in (0, 3, 9, True, '1', None):
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
