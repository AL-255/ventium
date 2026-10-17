"""Offline regressions: physical namespaces, large devices and honest metrics."""
import csv
from pathlib import Path
import tempfile
import unittest
import render_device_view as r


class PhysicalMapTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='physical-map-test-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.write('device.tsv',['key','value'],[['schema','ventium-physical-v1'],['part','xczu15eg-ffvb1156-2-i']])
        self.write('tiles.tsv',['tile','grid_x','grid_y','tile_type'],[
            ['CLEL_R_X0Y0',1000,1200,'CLEL_R'],['CLEM_X1Y0',1005,1200,'CLEM'],
            ['DSP_X0Y0',1010,1200,'DSP'],['RAMB_X0Y0',1015,1200,'BRAM'],
            ['INT_X0Y0',999,1202,'INT'],['INT_X1Y1',1008,1199,'INT']])
        self.write('sites.tsv',['site','site_type','tile','clock_region'],[
            ['SLICE_X0Y0','SLICEL','CLEL_R_X0Y0','X0Y0'],
            ['SLICE_X1Y0','SLICEM','CLEM_X1Y0','X0Y0'],
            ['DSP48E2_X0Y0','DSP48E2','DSP_X0Y0','X0Y0'],
            ['RAMB36_X0Y0','RAMB36','RAMB_X0Y0','X0Y0']])
        self.cells=[['soc/cpu/a','LUT6','SLICE_X0Y0','SLICEL.A6LUT'],
                    ['soc/video/b','LUT5','SLICE_X0Y0','SLICEL.A5LUT'],
                    ['soc/video/c','FDRE','SLICE_X0Y0','SLICEL.AFF'],
                    ['soc/mul/d','DSP48E2','DSP48E2_X0Y0','DSP48E2'],
                    ['soc/ram/e','RAMB36E2','RAMB36_X0Y0','RAMB36E2'],
                    ['VCC','VCC','','']]
        self.write_cells()
        (self.root/'complete.txt').write_text('PHYSICAL-MAP-EXPORT-COMPLETE\n')
        self.log='''--GLOBAL Congestion:
North Dir 2x2 Area, Max Cong = 91.25%, Congestion bounded by tiles:
 INT_X0Y0 -> INT_X1Y1
 INT_X0Y0 -> INT_X1Y1
Reporting congestion hotspots
'''

    def write(self,name,header,values):
        with (self.root/name).open('w',newline='') as out:
            writer=csv.writer(out,delimiter='\t');writer.writerow(header);writer.writerows(values)

    def write_cells(self):
        self.write('cells.tsv',['cell','ref_name','site','bel'],self.cells)

    def load(self):return r.load_export(self.root)

    def test_large_coordinates_no_wrap_or_occupied_crop(self):
        m=self.load()
        self.assertEqual(m['clbs']['SLICE_X0Y0']['x'],1000)
        self.assertEqual(m['clbs']['SLICE_X0Y0']['y'],1200)
        self.assertEqual(len(m['clbs']),2)
        self.assertFalse(m['clbs']['SLICE_X1Y0']['owners'])

    def test_resource_namespaces_do_not_collide(self):
        m=self.load()
        self.assertEqual(sum(m['parents'].values()),3)
        self.assertEqual(m['non_clb']['DSP48E2'],1)
        self.assertEqual(m['non_clb']['RAMB36'],1)

    def test_o5_o6_share_one_lut(self):
        self.assertEqual(self.load()['clbs']['SLICE_X0Y0']['luts'],{'A'})
        self.assertEqual(r.lut_slot('SLICE_X900Y1200/SLICEM.H6LUT'),'H')
        self.assertIsNone(r.lut_slot('SLICEL.AFF'))

    def test_mixed_owners_preserved(self):
        m=self.load();s=r.summarize(m,r.parse_congestion(self.log,m['tiles']))
        self.assertEqual(s['totals']['mixed_hierarchy_sites'],1)
        self.assertEqual(len(next(c for c in s['clbs'] if c['primitives'])['owners']),2)

    def test_unknown_placed_site_rejected(self):
        self.cells[0][2]='SLICE_X999Y999';self.write_cells()
        with self.assertRaisesRegex(ValueError,'unknown site'):self.load()

    def test_duplicate_cell_rejected(self):
        self.cells.append(self.cells[0]);self.write_cells()
        with self.assertRaisesRegex(ValueError,'duplicate primitive'):self.load()

    def test_duplicate_grid_tile_rejected(self):
        with (self.root/'tiles.tsv').open('a') as f:f.write('CLEL_R_X99Y99\t1000\t1200\tCLEL_R\n')
        with self.assertRaisesRegex(ValueError,'duplicate physical'):self.load()

    def test_no_keyword_guessing(self):
        self.cells[0][0]='soc/video/u_icache_lookalike';self.write_cells()
        self.assertEqual(list(self.load()['parents']),['soc/video'])

    def test_missing_row_field_rejected(self):
        with (self.root/'cells.tsv').open('a') as f:f.write('broken\tLUT6\n')
        with self.assertRaisesRegex(ValueError,'malformed row'):self.load()

    def test_legacy_csv_rejected(self):
        with self.assertRaisesRegex(ValueError,'legacy'):r.load_export(self.root/'cells.tsv')

    def test_incomplete_export_rejected(self):
        (self.root/'complete.txt').write_text('incomplete')
        with self.assertRaisesRegex(ValueError,'incomplete'):self.load()

    def test_native_tile_mapping_not_name_suffix(self):
        c=r.parse_congestion(self.log,self.load()['tiles'])
        self.assertEqual(c['windows'][0]['box'],[998.5,1198.5,1008.5,1202.5])
        self.assertEqual(c['windows'][0]['peak_percent'],91.25)

    def test_unreported_is_not_zero(self):
        c=r.parse_congestion(self.log,self.load()['tiles'])
        self.assertEqual({x['direction'] for x in c['windows']},{'North'})
        self.assertIsNone(c['global_vertical_percent'])

    def test_unknown_congestion_tile_rejected(self):
        with self.assertRaisesRegex(ValueError,'unknown tile'):
            r.parse_congestion(self.log.replace('INT_X1Y1','INT_X99Y99'),self.load()['tiles'])

    def test_no_congestion_history_is_not_zero(self):
        with self.assertRaises(ValueError):r.parse_congestion('No windows found',self.load()['tiles'])

    def test_last_native_section_only(self):
        c=r.parse_congestion(self.log.replace('91.25','99.9')+self.log,self.load()['tiles'])
        self.assertEqual({w['peak_percent'] for w in c['windows']},{91.25})

    def test_overlapping_windows_not_double_counted(self):
        m=self.load();s=r.summarize(m,r.parse_congestion(self.log,m['tiles']))
        self.assertEqual(s['region_hierarchies'][0]['sites'],2)
        self.assertEqual(sum(n for p,n in s['region_hierarchies'][0]['parents']),3)

    def test_exact_rectangle_union(self):
        result=r.rectangle_union([[0,0,2,2],[1,1,3,3],[0,0,2,2]])
        self.assertEqual(sum((b[2]-b[0])*(b[3]-b[1]) for b in result),7)
        self.assertEqual(r.rectangle_union([]),[])

    def test_totals_checked_against_native(self):
        m=self.load();s=r.summarize(m,r.parse_congestion(self.log,m['tiles']),1)
        r.check_totals(s,{'clbs':[1,2],'luts':[1,16]})
        with self.assertRaisesRegex(ValueError,'LUT'):r.check_totals(s,{'clbs':[1,2],'luts':[2,16]})
        with self.assertRaisesRegex(ValueError,'CLB'):r.check_totals(s,{'clbs':[2,2],'luts':[1,16]})

    def test_legend_parent_names_unique(self):
        self.assertEqual(r.short_labels(['soc/a/unit','soc/b/unit']),['a/unit','b/unit'])

    def test_multiple_slices_in_one_tile_are_not_overwritten(self):
        with (self.root/'sites.tsv').open('a') as f:
            f.write('SLICE_X2Y0\tSLICEL\tCLEL_R_X0Y0\tX0Y0\n')
        m=self.load();s=r.summarize(m,r.parse_congestion(self.log,m['tiles']))
        sharing=[c for c in s['clbs'] if c['tile']=='CLEL_R_X0Y0']
        self.assertEqual({c['tile_site_index'] for c in sharing},{0,1})
        self.assertEqual({c['tile_site_count'] for c in sharing},{2})

    def test_compact_columns_keep_unoccupied_sites_and_sort_large_coordinates(self):
        m=self.load();s=r.summarize(m,r.parse_congestion(self.log,m['tiles']))
        before=repr(s)
        columns=r.compact_columns(list(reversed(s['clbs'])))
        self.assertEqual(columns,{1000:0,1005:1})
        geometry=[r.site_geometry(c,columns) for c in s['clbs']]
        self.assertEqual(geometry,[(-.5,1199.5,1),(.5,1199.5,1)])
        self.assertEqual(repr(s),before)

    def test_compact_columns_preserve_vertical_alignment_and_partial_gaps(self):
        sites=[dict(x=10,y=5,tile_site_count=1,tile_site_index=0),
               dict(x=1000,y=5,tile_site_count=1,tile_site_index=0),
               dict(x=1000,y=1200,tile_site_count=1,tile_site_index=0)]
        columns=r.compact_columns(sites)
        geometry=[r.site_geometry(c,columns) for c in sites]
        self.assertEqual(geometry,[(-.5,4.5,1),(.5,4.5,1),(.5,1199.5,1)])

    def test_compact_columns_keep_multiple_slices_edge_to_edge(self):
        sites=[dict(x=1000,y=1200,tile_site_count=2,tile_site_index=i) for i in range(2)]
        columns=r.compact_columns(sites)
        self.assertEqual([r.site_geometry(c,columns) for c in sites],
                         [(-.5,1199.5,.5),(0,1199.5,.5)])
        self.assertEqual(r.site_geometry(sites[1]),(1000,1199.5,.5))

    def test_site_type_qualified_bel_and_unique_nonclb_sites(self):
        self.cells.append(['soc/mul/internal','DSP_ALU','DSP48E2_X0Y0','DSP_ALU'])
        self.write_cells();m=self.load()
        self.assertEqual(m['non_clb']['DSP48E2'],2)
        self.assertEqual(m['non_clb_sites']['DSP48E2'],1)

    def test_utilization_parser_uses_exact_row_names(self):
        text='| CLB LUTs | 42 | 0 | 0 | 80 | 52.50 |\n| CLB | 6 | 0 | 0 | 10 | 60.00 |\n'
        self.assertEqual(r.utilization_counts(text),{'clbs':[6,10],'luts':[42,80]})
        with self.assertRaises(ValueError):r.utilization_counts(text+text)

    def test_timing_cells_are_translated_and_clock_fanout_excluded(self):
        text='''Slack (VIOLATED) : -1.000ns
  Source: soc/u_core/eip/C
  Destination: soc/u_core/data/D
  Requirement: 25.000ns
  Data Path Delay: 26.000ns (logic 6.000ns (23.077%) route 20.000ns (76.923%))
  Logic Levels: 12
 SLICE_X0Y0 FDRE
 net (fo=999, routed) 2.000 2.000 soc/u_core/clk
 net (fo=9, routed) 1.000 3.000 soc/u_core/addr
 SLICE_X1Y0 FDRE
 data arrival time
'''
        result=r.timing_summary(text,self.load()['sites'])
        self.assertEqual(result['waypoints'][0]['x'],1000)
        self.assertAlmostEqual(result['conditional_period_budget_mhz'],1000/26)
        self.assertEqual(len(result['largest_fanouts']),1)
        self.assertEqual(result['largest_fanouts'][0]['fanout'],9)


if __name__=='__main__':unittest.main()
