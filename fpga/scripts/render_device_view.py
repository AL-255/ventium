#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Physical, hierarchy-colored CLB maps from export_physical_map.tcl.

Legacy module,sub,x,y CSV is rejected: it loses resource namespaces, empty
sites and physical tile coordinates. No Vivado execution occurs here.
"""
import argparse
from collections import Counter, defaultdict
import csv
import gzip
import hashlib
import json
import math
from pathlib import Path
import re


def rows(path, fields):
    with Path(path).open(newline='') as stream:
        reader = csv.DictReader(stream, delimiter='\t')
        if reader.fieldnames != fields:
            raise ValueError(f'{path}: expected {fields}, got {reader.fieldnames}')
        for number, row in enumerate(reader, 2):
            if None in row or any(value is None for value in row.values()):
                raise ValueError(f'{path}:{number}: malformed row')
            yield row


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def is_clb(site_type):
    return site_type in ('SLICEL', 'SLICEM', 'SLICE')


def lut_slot(bel):
    # O5/O6 can share ONE physical LUT; count its letter once, not twice.
    match = re.fullmatch(r'([A-H])[56]LUT', bel.rsplit('/', 1)[-1].rsplit('.', 1)[-1])
    return match[1] if match else None


def load_export(directory):
    directory = Path(directory)
    if not directory.is_dir():
        raise ValueError('legacy mixed-coordinate CSV is unsafe; supply a physical export directory')
    if (directory/'complete.txt').read_text().strip() != 'PHYSICAL-MAP-EXPORT-COMPLETE':
        raise ValueError('incomplete Vivado export')
    metadata = {r['key']: r['value'] for r in rows(directory/'device.tsv', ['key', 'value'])}
    if metadata.get('schema') != 'ventium-physical-v1':
        raise ValueError('unsupported physical export schema')
    tiles = {}
    coordinates = set()
    for r in rows(directory/'tiles.tsv', ['tile', 'grid_x', 'grid_y', 'tile_type']):
        xy = (int(r['grid_x']), int(r['grid_y']))
        if r['tile'] in tiles or xy in coordinates:
            raise ValueError(f'duplicate physical tile/name: {r}')
        tiles[r['tile']] = dict(x=xy[0], y=xy[1], type=r['tile_type'])
        coordinates.add(xy)
    sites = {}
    for r in rows(directory/'sites.tsv', ['site', 'site_type', 'tile', 'clock_region']):
        if r['tile'] not in tiles or r['site'] in sites:
            raise ValueError(f'unknown tile or duplicate site: {r}')
        sites[r['site']] = dict(**r, **tiles[r['tile']], owners=Counter(), luts=set(), refs=Counter())
    seen = set()
    unplaced = Counter()
    non_clb = Counter()
    non_clb_sites = defaultdict(set)
    parents = Counter()
    for r in rows(directory/'cells.tsv', ['cell', 'ref_name', 'site', 'bel']):
        if r['cell'] in seen:
            raise ValueError(f'duplicate primitive: {r["cell"]}')
        seen.add(r['cell'])
        if not r['site']:
            unplaced[r['ref_name']] += 1
            continue
        if r['site'] not in sites:
            raise ValueError(f'placed cell references unknown site: {r}')
        s = sites[r['site']]
        if not is_clb(s['site_type']):
            non_clb[s['site_type']] += 1
            non_clb_sites[s['site_type']].add(r['site'])
            continue
        parent = r['cell'].rsplit('/', 1)[0] if '/' in r['cell'] else '(top)'
        parents[parent] += 1
        s['owners'][parent] += 1
        s['refs'][r['ref_name']] += 1
        slot = lut_slot(r['bel'])
        if slot:
            s['luts'].add(slot)
    clbs = {n: s for n, s in sites.items() if is_clb(s['site_type'])}
    if not clbs or not parents:
        raise ValueError('no CLB sites/placed primitives')
    return dict(metadata=metadata, tiles=tiles, sites=sites, clbs=clbs, parents=parents,
                non_clb=non_clb, non_clb_sites={k:len(v) for k,v in non_clb_sites.items()},
                unplaced=unplaced, primitive_count=len(seen))


def tile_box(tiles, lower, upper):
    if lower not in tiles or upper not in tiles:
        raise ValueError(f'congestion refers to unknown tile: {lower}, {upper}')
    a, b = tiles[lower], tiles[upper]
    return [min(a['x'], b['x'])-.5, min(a['y'], b['y'])-.5,
            max(a['x'], b['x'])+.5, max(a['y'], b['y'])+.5]


def parse_congestion(text, tiles):
    """Final native GLOBAL windows, not guessed SLICE-to-INT coordinates.

    Percentages are directional window maxima, NOT a measurement at every
    tile. Missing coverage means unknown. Pin clusters are a different stage.
    """
    if '--GLOBAL Congestion:' not in text:
        raise ValueError('native run log has no final global congestion section')
    section = text.rsplit('--GLOBAL Congestion:', 1)[1].split('Reporting congestion hotspots', 1)[0]
    header = re.compile(r'(North|South|East|West) Dir (\d+)x(\d+) Area, Max Cong = ([\d.]+)%')
    windows = []
    direction = None
    for line in section.splitlines():
        match = header.search(line)
        if match:
            direction, w, h, peak = match.groups()
            peak = float(peak)
            if peak < 0:
                raise ValueError('negative congestion')
        elif direction:
            match = re.fullmatch(r'\s*(\w+_X\d+Y\d+) -> (\w+_X\d+Y\d+)\s*', line)
            if match:
                lo, hi = match.groups()
                windows.append(dict(direction=direction, size=[int(w), int(h)], peak_percent=peak,
                                    lower_tile=lo, upper_tile=hi, box=tile_box(tiles, lo, hi)))
    if not windows:
        raise ValueError('no recognized native congestion windows')
    pin_windows = []
    for lo, hi in re.findall(r'\[([A-Z0-9_]+_X\d+Y\d+) -> ([A-Z0-9_]+_X\d+Y\d+)\]', text):
        pin_windows.append(dict(lower_tile=lo, upper_tile=hi, box=tile_box(tiles, lo, hi)))
    pin_count = re.findall(r'At least (\d+) CLBs have high pin utilization', text)
    vertical = re.findall(r'Global Vertical Routing Utilization\s*=\s*([\d.]+)', text)
    horizontal = re.findall(r'Global Horizontal Routing Utilization\s*=\s*([\d.]+)', text)
    return dict(windows=windows, pin_windows=pin_windows,
                high_pin_clbs=int(pin_count[-1]) if pin_count else None,
                global_vertical_percent=float(vertical[-1]) if vertical else None,
                global_horizontal_percent=float(horizontal[-1]) if horizontal else None)


def summarize(model, congestion, groups=14):
    parents = model['parents']
    order = sorted(parents, key=lambda p: (-parents[p], p))[:groups]
    other = '(other retained hierarchies)'
    if len(order) < len(parents):
        order.append(other)
    ranks = {p: i for i, p in enumerate(order)}
    clbs = []
    tiles_to_sites = defaultdict(list)
    for name, s in model['clbs'].items():
        tiles_to_sites[s['tile']].append(name)
    for names in tiles_to_sites.values():
        names.sort()
    for name, s in sorted(model['clbs'].items()):
        grouped = Counter()
        for owner, n in s['owners'].items():
            grouped[ranks[owner if owner in ranks else other]] += n
        sharing = tiles_to_sites[s['tile']]
        clbs.append(dict(site=name, tile=s['tile'], x=s['x'], y=s['y'],
                         tile_site_index=sharing.index(name), tile_site_count=len(sharing),
                         owners=sorted(grouped.items()), primitives=sum(s['owners'].values()),
                         lut_slots=len(s['luts']), hierarchy_count=len(s['owners'])))
    regions = []
    for direction in ('North', 'South', 'East', 'West'):
        wins = [w for w in congestion['windows'] if w['direction'] == direction]
        if not wins:
            continue
        contained = []
        weights = Counter()
        for n, s in model['clbs'].items():
            if any(w['box'][0] <= s['x'] <= w['box'][2] and w['box'][1] <= s['y'] <= w['box'][3] for w in wins):
                contained.append(n)
                weights.update(s['owners'])
        regions.append(dict(direction=direction, sites=len(contained),
                            used_sites=sum(bool(model['clbs'][n]['owners']) for n in contained),
                            primitives=sum(weights.values()),
                            peak_percent=max(w['peak_percent'] for w in wins),
                            lut_slots=sum(len(model['clbs'][n]['luts']) for n in contained),
                            parents=weights.most_common(12)))
    pin_parents = Counter()
    for s in model['clbs'].values():
        if any(w['box'][0] <= s['x'] <= w['box'][2] and w['box'][1] <= s['y'] <= w['box'][3] for w in congestion['pin_windows']):
            pin_parents.update(s['owners'])
    return dict(schema='ventium-map-v1', metadata=model['metadata'], clbs=clbs,
                groups=[dict(path=p, primitives=parents[p] if p in parents else sum(v for k, v in parents.items() if k not in ranks)) for p in order],
                totals=dict(clb_sites=len(clbs), occupied_clb_sites=sum(s['primitives'] > 0 for s in clbs),
                            mixed_hierarchy_sites=sum(s['hierarchy_count'] > 1 for s in clbs),
                            mapped_clb_primitives=sum(parents.values()),
                            lut_slots=sum(s['lut_slots'] for s in clbs),
                            non_clb_primitives=dict(model['non_clb']), unplaced_primitives=dict(model['unplaced'])),
                congestion=congestion, region_hierarchies=regions, high_pin_hierarchies=pin_parents.most_common(),
                all_hierarchies=parents.most_common())


def rectangle_union(boxes):
    """Exact non-overlapping rectangle union, without raster rounding/alpha sums."""
    edges = sorted({y for b in boxes for y in (b[1], b[3])})
    result = []
    for y0, y1 in zip(edges, edges[1:]):
        intervals = sorted((b[0], b[2]) for b in boxes if b[1] <= y0 and b[3] >= y1)
        merged = []
        for x0, x1 in intervals:
            if merged and x0 <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], x1)
            else:merged.append([x0,x1])
        result.extend([x0,y0,x1,y1] for x0,x1 in merged)
    return result


def utilization_counts(text):
    result = {}
    for name, key in (('CLB LUTs','luts'), ('CLB','clbs')):
        matches=re.findall(r'^\|\s*'+re.escape(name)+r'\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|',text,re.M)
        if len(matches)!=1:raise ValueError(f'missing/ambiguous utilization row: {name}')
        result[key]=list(map(int,matches[0]))
    return result


def check_totals(data, counts):
    total=data['totals']
    if [total['occupied_clb_sites'],total['clb_sites']]!=counts['clbs']:
        raise ValueError('CLB inventory disagrees with Vivado utilization')
    if total['lut_slots']!=counts['luts'][0]:
        raise ValueError('physical LUT slots disagree with Vivado utilization')
    if sum(g['primitives'] for g in data['groups'])!=total['mapped_clb_primitives']:
        raise ValueError('hierarchy grouping lost primitives')
    data['native_utilization']=counts


def timing_summary(text, sites):
    """Timing report waypoints are cell placements, NOT routed wire geometry."""
    paths=re.split(r'(?=^Slack \()',text,flags=re.M)[1:]
    if not paths:raise ValueError('no native timing paths')
    first=paths[0]
    field=lambda label: re.search(r'^  '+re.escape(label)+r':\s+(.+)$',first,re.M)[1]
    slack=float(re.search(r'^Slack .*?:\s+(-?[\d.]+)ns',first,re.M)[1])
    period=float(re.search(r'^  Requirement:\s+([\d.]+)ns',first,re.M)[1])
    delay=re.search(r'Data Path Delay:\s+([\d.]+)ns\s+\(logic ([\d.]+)ns \(([\d.]+)%\)\s+route ([\d.]+)ns \(([\d.]+)%\)\)',first)
    if not delay:raise ValueError('unrecognized native data path summary')
    waypoints=[]
    for name in re.findall(r'\bSLICE_X\d+Y\d+\b',first.split('data arrival time',1)[0]):
        if name not in sites:raise ValueError(f'unknown timing site {name}')
        point=dict(site=name,x=sites[name]['x'],y=sites[name]['y'])
        if not waypoints or waypoints[-1]!=point:waypoints.append(point)
    fanout=[]
    for fo,ns,name in re.findall(r'net \(fo=(\d+), routed\)\s+([\d.]+)\s+[\d.]+\s+(\S+)',first):
        if '/u_core/' in name and name.rsplit('/',1)[-1]!='clk':
            fanout.append(dict(fanout=int(fo),delay_ns=float(ns),net=name))
    return dict(path_count=len(paths),source=field('Source'),destination=field('Destination'),
                setup_slack_ns=slack,period_ns=period,conditional_period_budget_mhz=1000/(period-slack),
                data_delay_ns=float(delay[1]),logic_ns=float(delay[2]),route_ns=float(delay[4]),route_percent=float(delay[5]),
                logic_levels=int(re.search(r'Logic Levels:\s+(\d+)',first)[1]),
                waypoints=waypoints,largest_fanouts=sorted(fanout,key=lambda x:-x['fanout'])[:8],
                scope='Worst reported setup path; waypoint lines are not routed wire shapes')


def short_labels(paths):
    result = []
    for path in paths:
        parts = path.split('/')
        for n in range(min(2,len(parts)), len(parts)+1):
            tail = '/'.join(parts[-n:])
            if sum(p == tail or p.endswith('/'+tail) for p in paths) == 1:
                break
        result.append(tail)
    return result


def plot(data, output, image_id):
    import numpy as np
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.collections import PolyCollection
    from matplotlib.patches import Patch, Rectangle
    from matplotlib.colors import Normalize
    from matplotlib.cm import ScalarMappable

    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    clbs = data['clbs']
    xs, ys = [s['x'] for s in clbs], [s['y'] for s in clbs]
    bounds = [min(xs)-2, max(xs)+2, min(ys)-2, max(ys)+2]
    cmap = plt.get_cmap('tab20')
    palette=list(range(0,20,2))+list(range(1,20,2))
    colors = [cmap(palette[i]) for i in range(len(data['groups']))]
    if data['groups'][-1]['path'].startswith('('):colors[-1] = '#7f8996'
    labels = short_labels([g['path'] for g in data['groups']])
    title = f"{data['metadata']['part']} • routed image {image_id}"
    total = data['totals']
    plt.rcParams.update({'font.family': 'DejaVu Sans', 'font.size': 10, 'axes.titleweight': 'bold',
                         'axes.spines.top': False, 'axes.spines.right': False, 'savefig.facecolor': 'white'})

    def setup(ax, local_bounds=None):
        box = local_bounds or bounds
        ax.set_xlim(box[0], box[1]); ax.set_ylim(box[3], box[2])
        ax.set_aspect('equal')
        ax.set_facecolor('#f4f6f8')
        ax.set_xlabel('Physical tile-grid X')
        ax.set_ylabel('Physical tile-grid Y (downward)')

    def geometry(s):
        width = 1/s['tile_site_count']
        return s['x']-.5+s['tile_site_index']*width, s['y']-.5, width

    def rect(x, y, w, h):
        return [(x,y), (x+w,y), (x+w,y+h), (x,y+h)]

    def backdrop(ax):
        polygons, paint = [], []
        for s in clbs:
            x,y,w=geometry(s)
            polygons.append(rect(x,y,w,1))
            paint.append('#c8cdd3' if s['primitives'] else '#ffffff')
        ax.add_collection(PolyCollection(polygons, facecolors=paint, edgecolors='none', rasterized=True))

    fig = plt.figure(figsize=(15.5, 11))
    ax = fig.add_axes([.065,.11,.60,.78]); setup(ax)
    polygons, paint = [], []
    for s in clbs:
        x,y,w=geometry(s)
        if not s['owners']:
            polygons.append(rect(x,y,w,1)); paint.append('#ffffff')
        else:
            # Preserve all hierarchy owners as proportional strips, not just
            # the dominant group's color. Values are cell shares, not capacity.
            for group, count in s['owners']:
                h=count/s['primitives']
                polygons.append(rect(x,y,w,h));paint.append(colors[group]);y+=h
    ax.add_collection(PolyCollection(polygons,facecolors=paint,edgecolors='none',rasterized=True))
    fig.suptitle('CLB placement by synthesized hierarchy', x=.065, ha='left', y=.98, fontsize=20, weight='bold')
    fig.text(.065,.94,title,fontsize=11,color='#465366')
    handles=[Patch(facecolor=c,label=f'{label}  ·  {g["primitives"]:,}') for c,label,g in zip(colors,labels,data['groups'])]
    handles += [Patch(facecolor='white',edgecolor='#aaa',label='Available, unoccupied CLB'),
                Patch(facecolor='#f4f6f8',label='No CLB site / device gap')]
    fig.legend(handles=handles,loc='upper left',bbox_to_anchor=(.68,.88),frameon=False,fontsize=9,
               title='Exact hierarchy parent · placed primitives',labelspacing=1.0)
    fig.text(.69,.20,f"{total['occupied_clb_sites']:,} / {total['clb_sites']:,} CLBs occupied\n"
             f"{100*total['occupied_clb_sites']/total['clb_sites']:.2f}% site occupancy\n"
             f"{total['mixed_hierarchy_sites']:,} sites have mixed ownership",fontsize=11,linespacing=1.8)
    fig.text(.065,.035,'Each site is split by primitive-owner share; strip area is NOT LUT capacity.\n'
             'DSP/BRAM coordinates are excluded. White = genuinely empty CLB; grey = non-CLB geography.',fontsize=10,color='#465366')
    fig.savefig(output/'clb-hierarchy.png',dpi=220);plt.close(fig)

    # Current exporter targets UltraScale/UltraScale+ SLICEs (eight LUTs).
    # Do not silently apply that denominator to a different architecture.
    if not re.match(r'xc(zu|ku|vu|k26)',data['metadata']['part']):
        raise ValueError('LUT density capacity is only qualified for UltraScale(+) parts')
    fig,ax=plt.subplots(figsize=(11,10));setup(ax)
    polygons=[];values=[]
    for s in clbs:
        x,y,w=geometry(s);polygons.append(rect(x,y,w,1));values.append(s['lut_slots'])
    coll=PolyCollection(polygons,array=np.array(values),cmap='viridis',edgecolors='none',rasterized=True)
    coll.set_clim(0,8);ax.add_collection(coll)
    fig.colorbar(coll,ax=ax,shrink=.7,label='Distinct placed LUT letters (O5/O6 combined; out of 8)')
    ax.set_title('CLB LUT-slot occupancy — placement density, not routing congestion\n'+title,fontsize=12)
    fig.tight_layout();fig.savefig(output/'clb-lut-density.png',dpi=220);plt.close(fig)

    fig,axes=plt.subplots(2,2,figsize=(14,12))
    norm=Normalize(vmin=85,vmax=100);heat=plt.get_cmap('inferno')
    for ax,direction in zip(axes.flat,('North','South','East','West')):
        setup(ax);backdrop(ax)
        wins=[w for w in data['congestion']['windows'] if w['direction']==direction]
        if wins:
            # Paint the UNION once: overlapping windows must not darken/sum.
            peak=max(w['peak_percent'] for w in wins)
            polygons=[rect(x0,y0,x1-x0,y1-y0) for x0,y0,x1,y1 in rectangle_union([w['box'] for w in wins])]
            ax.add_collection(PolyCollection(polygons,facecolors=[heat(norm(peak))],edgecolors='none',zorder=2))
            for w in wins:
                x0,y0,x1,y1=w['box']
                ax.add_patch(Rectangle((x0,y0),x1-x0,y1-y0,fill=False,edgecolor='#ad3500',linewidth=.6,zorder=3))
            ax.set_title(f'{direction} · reported peak {peak:.2f}% · {wins[0]["size"][0]}×{wins[0]["size"][1]} windows')
        else:ax.set_title(f'{direction} · no reported window (not a zero)')
        for w in data['congestion']['pin_windows']:
            x0,y0,x1,y1=w['box']
            ax.plot((x0+x1)/2,(y0+y1)/2,'+',color='#0074d9',ms=5,mew=.9,zorder=4)
    fig.suptitle('Native router congestion windows\n'+title,fontsize=16,weight='bold')
    fig.subplots_adjust(left=.07,right=.88,bottom=.13,top=.88,hspace=.30,wspace=.22)
    cax=fig.add_axes([.91,.30,.015,.40]);fig.colorbar(ScalarMappable(norm=norm,cmap=heat),cax=cax,label='Reported window maximum (%)')
    fig.text(.07,.035,'Colored regions = final GLOBAL router windows; grey/outside = unreported, NOT 0% congestion.\n'
             'Blue + = top-ten high-pin CLB clusters from pre-routing diagnostics (different metric/stage).\n'
             'No interpolation or fabricated per-tile routing-utilization values.',fontsize=10,color='#465366')
    fig.savefig(output/'routing-congestion.png',dpi=200);plt.close(fig)

    if 'timing' in data:
        fig=plt.figure(figsize=(15,7.5));ax=fig.add_axes([.07,.16,.58,.69])
        windows=data['congestion']['windows'];waypoints=data['timing']['waypoints']
        xlist=[v for w in windows for v in (w['box'][0],w['box'][2])]+[p['x'] for p in waypoints]
        ylist=[v for w in windows for v in (w['box'][1],w['box'][3])]+[p['y'] for p in waypoints]
        zoom=[min(xlist)-8,max(xlist)+8,min(ylist)-8,max(ylist)+8]
        setup(ax,zoom)
        polygons=[];paint=[]
        for s in clbs:
            if not (zoom[0]<=s['x']<=zoom[1] and zoom[2]<=s['y']<=zoom[3]):continue
            x,y,w=geometry(s)
            if not s['owners']:
                polygons.append(rect(x,y,w,1));paint.append('#ffffff')
            for group,count in s['owners']:
                h=count/s['primitives'];polygons.append(rect(x,y,w,h));paint.append(colors[group]);y+=h
        ax.add_collection(PolyCollection(polygons,facecolors=paint,edgecolors='none'))
        for direction,color in zip(('North','South','East','West'),('#802060','#ad5000','#006d6f','#15549a')):
            wins=[w for w in windows if w['direction']==direction]
            for w in wins:
                x0,y0,x1,y1=w['box']
                ax.add_patch(Rectangle((x0,y0),x1-x0,y1-y0,fill=False,edgecolor=color,lw=.8,zorder=3))
        ax.plot([p['x'] for p in waypoints],[p['y'] for p in waypoints],color='#15191c',lw=.8,alpha=.7,zorder=4)
        ax.scatter([waypoints[0]['x'],waypoints[-1]['x']],[waypoints[0]['y'],waypoints[-1]['y']],s=50,facecolors='white',edgecolors='black',zorder=5)
        for p,label in ((waypoints[0],'EIP source'),(waypoints[-1],'paired-load return')):
            ax.annotate(label,(p['x'],p['y']),xytext=(8,8),textcoords='offset points',fontsize=8,
                        bbox=dict(fc='white',ec='none',alpha=.9),zorder=6)
        fig.suptitle('Optimization focus: routed hotspots and worst-path cell locations\n'+title,fontsize=16,weight='bold')
        timing=data['timing']
        measured=data.get('measured_core_mhz')
        measured_label=f'{measured:.3f} MHz measured hardware clock' if measured is not None else 'Measured hardware clock: not supplied'
        fig.text(.69,.80,'Worst setup path',fontsize=14,weight='bold')
        fig.text(.69,.72,f"{timing['logic_levels']} logic levels\n{timing['data_delay_ns']:.3f} ns data delay\n"
                 f"{timing['route_percent']:.1f}% routing delay\n{timing['conditional_period_budget_mhz']:.2f} MHz conditional STA budget\n{measured_label}",
                 fontsize=11,linespacing=1.8,va='top')
        handles=[Patch(facecolor=c,label=l) for c,l in zip(colors,labels) if 'u_icache' in l or 'u_regfile' in l or 'u_l1d' in l or l=='u_core/u_core']
        fig.legend(handles=handles,loc='upper left',bbox_to_anchor=(.68,.38),frameon=False,fontsize=9)
        fig.text(.07,.045,'Rectangle outlines: native directional congestion windows. Black line: consecutive timing-path CELL locations, not wire routes.\n'
                 'Synthesized u_icache/u_regfile hierarchies include absorbed frontend, decode and address logic; names do not imply cache/GPR storage alone.',fontsize=10,color='#465366')
        fig.savefig(output/'optimization-focus.png',dpi=220);plt.close(fig)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    source=ap.add_mutually_exclusive_group(required=True)
    source.add_argument('--export',type=Path)
    source.add_argument('--data',type=Path,help='regenerate from compact .json.gz without Vivado')
    ap.add_argument('--route-log',type=Path)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--image-id',required=True)
    ap.add_argument('--measured-mhz',type=float,help='optional independently measured board clock; not the XDC target')
    ap.add_argument('--groups',type=int,default=14)
    args=ap.parse_args()
    if not 1<=args.groups<=19:ap.error('--groups must be 1..19')
    if args.measured_mhz is not None and (not math.isfinite(args.measured_mhz) or args.measured_mhz<=0):
        ap.error('--measured-mhz must be finite and positive')
    if args.export:
        if not args.route_log:ap.error('--route-log is required with --export')
        model=load_export(args.export)
        congestion=parse_congestion(args.route_log.read_text(),model['tiles'])
        data=summarize(model,congestion,args.groups)
        data['totals']['occupied_non_clb_sites']=model['non_clb_sites']
        check_totals(data,utilization_counts((args.export/'utilization.rpt').read_text()))
        data['timing']=timing_summary((args.export/'timing.rpt').read_text(),model['sites'])
        data['measured_core_mhz']=args.measured_mhz
        data['provenance']={str(p):digest(p) for p in [args.route_log,*sorted(args.export.iterdir())] if p.is_file()}
        checkpoint=Path(model['metadata']['checkpoint'])
        data['provenance'][str(checkpoint)]=digest(checkpoint)
    else:
        with gzip.open(args.data,'rt') as stream:data=json.load(stream)
        if data['schema']!='ventium-map-v1':raise ValueError('unsupported compact map schema')
        if data.get('image_id')!=args.image_id:raise ValueError('cannot relabel another image\'s map')
        if args.measured_mhz is not None and args.measured_mhz!=data.get('measured_core_mhz'):
            raise ValueError('cannot overwrite a compact map\'s measured clock')
    data['image_id']=args.image_id
    args.output.mkdir(parents=True,exist_ok=True)
    raw=json.dumps(data,separators=(',',':'),sort_keys=True).encode()
    (args.output/'physical-map.json.gz').write_bytes(gzip.compress(raw,mtime=0))
    summary={k:v for k,v in data.items() if k!='clbs'}
    (args.output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    plot(data,args.output,args.image_id)
    print(json.dumps(data['totals'],indent=2))


if __name__=='__main__':main()
