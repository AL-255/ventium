#!/usr/bin/env python3
"""Host-only synthetic compiler/observer fixtures; never launches Verilator."""
import json
import argparse
import os
from pathlib import Path
import tempfile
import unittest

import memory_geometry_proof as proof
from check_memory_geometry import check


MAPPING = {'S_LOAD': 3, 'S_EXEC': 5, 'S_PIPE': 28, 'S_WALK': 40, 'K_EXT': 5}
PROFILE = 'a' * 64


class ProofTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ventium-geometry-proof-test.')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.roles = {}
        for role in ('core', 'kind', 'top', 'bus', 'adapter', 'observer', 'compiler'):
            p = self.root / role
            p.write_text('synthetic source ' + role)
            self.roles[role] = str(p)
        self.model = self.root/'model'
        self.config = {'cwd': str(self.root), 'model_dir': str(self.model),
                       'argv': ['--cc', '--dump-tree-json', '--no-json-ids', '-Mdir', str(self.model)],
                       'version': 'Verilator 5.046 synthetic HOST TEST',
                       'sources': list(self.roles.values()), 'roles': self.roles}
        self.before = proof.begin(self.config)
        self.model.mkdir()
        self.ast = self.model/'Vventium_top_014_width.tree.json'
        self.cpp = self.model/'Vventium_top.cpp'
        self.cpp.write_text('synthetic generated model')
        self.tree = {'type': 'NETLIST', 'children': []}
        for names, role, variables, addr in [
                (('S_LOAD', 'S_EXEC', 'S_PIPE', 'S_WALK'), 'core', ('state', 'walk_ret_state'), '0x1'),
                (('K_EXT',), 'kind', ('q_kind',), '0x2')]:
            items = [{'type': 'ENUMITEM', 'name': name, 'loc': self.roles[role]+',1:1,1:9',
                      'valuep': [{'type': 'CONST', 'name': "7'h"+format(MAPPING[name], 'x')}]}
                     for name in names]
            self.tree['children'].append({'type': 'ENUMDTYPE', 'addr': addr, 'itemsp': items})
            self.tree['children'] += [{'type': 'VAR', 'name': v, 'loc': self.roles['core']+',1:1,1:9',
                                       'dtypep': addr} for v in variables]
        self.ast.write_text(json.dumps(self.tree))
        self.vf = self.model/'Vventium_top__verFiles.dat'
        self.write_dependencies()

    def write_dependencies(self, extra=None):
        lines = ['C "' + ' '.join(self.before['argv']) + '"']
        for p in [*self.roles.values(), *([extra] if extra else [])]:
            fp = proof.fingerprint(p)
            lines.append(f'S {fp["size"]} {fp["inode"]} {fp["ctime_ns"]//10**9} {fp["ctime_ns"]%10**9} '
                         f'{fp["mtime_ns"]//10**9} {fp["mtime_ns"]%10**9} "test-token" "{p}"')
        for p in (self.ast, self.cpp):
            lines.append(f'T 0 0 0 0 0 0 "unhashed" "{p}"')
        self.vf.write_text('\n'.join(lines)+'\n')

    def seal(self):
        return proof.seal(self.before, self.vf, self.ast)

    def test_complete_and_binding(self):
        receipt = self.seal()
        self.assertEqual(receipt['mapping'], MAPPING)
        header = self.root/'memory_geometry_model_map.h'
        header.write_text(proof.header(receipt))
        binary = self.root/'model.bin'
        binary.write_bytes(b'synthetic linked model' + proof.digest(receipt).encode())
        binding = proof.bind(receipt, binary, header)
        self.assertEqual(proof.verify_binding(receipt, binding, binary), proof.digest(receipt))
        binary.write_bytes(b'wrong executable')
        with self.assertRaises(ValueError): proof.verify_binding(receipt, binding, binary)

    def test_existing_model(self):
        with self.assertRaises(ValueError): proof.begin(self.config)

    def test_relative_source_locations(self):
        for node in proof.nodes(self.tree):
            if 'loc' in node:
                node['loc'] = node['loc'].replace(str(self.root) + '/', '')
        self.ast.write_text(json.dumps(self.tree))
        self.assertEqual(self.seal()['mapping'], MAPPING)

    def test_symlink_source_locations(self):
        alias = self.root/'source-alias'
        alias.symlink_to(self.root, target_is_directory=True)
        for node in proof.nodes(self.tree):
            if 'loc' in node:
                node['loc'] = node['loc'].replace(str(self.root) + '/', str(alias) + '/')
        self.ast.write_text(json.dumps(self.tree))
        self.assertEqual(self.seal()['mapping'], MAPPING)

    def test_wrong_same_basename_source(self):
        other = self.root/'other'
        other.mkdir()
        (other/'core').write_text('not the compiled core')
        self.tree['children'][0]['itemsp'][0]['loc'] = str(other/'core')+',1:1,1:9'
        self.ast.write_text(json.dumps(self.tree))
        with self.assertRaises(ValueError): self.seal()

    def test_malformed_source_location(self):
        self.tree['children'][0]['itemsp'][0]['loc'] = self.roles['core']+',not-a-source-range'
        self.ast.write_text(json.dumps(self.tree))
        with self.assertRaises(ValueError): self.seal()

    def test_typedef_reference(self):
        self.tree['children'].append({'type': 'REFDTYPE', 'addr': '0x3', 'refDTypep': '0x1'})
        next(n for n in self.tree['children'] if n.get('name') == 'state')['dtypep'] = '0x3'
        self.ast.write_text(json.dumps(self.tree))
        self.assertEqual(self.seal()['mapping'], MAPPING)

    def test_binary_missing_profile(self):
        receipt = self.seal()
        header = self.root/'map.h'
        header.write_text(proof.header(receipt))
        binary = self.root/'bad.bin'
        binary.write_text('old model with no profile')
        with self.assertRaises(ValueError): proof.bind(receipt, binary, header)

    def test_stale_source(self):
        Path(self.roles['core']).write_text('changed after begin')
        with self.assertRaises(ValueError): self.seal()

    def test_uncovered_source(self):
        extra = self.root/'unlisted.svh'
        extra.write_text('missed include')
        self.write_dependencies(str(extra))
        with self.assertRaises(ValueError): self.seal()

    def test_mismatched_command(self):
        self.vf.write_text(self.vf.read_text().replace('--cc ', '--cc +define+WRONG '))
        with self.assertRaises(ValueError): self.seal()

    def test_mismatched_dependency_stats(self):
        self.vf.write_text(self.vf.read_text().replace('S ', 'S 999 ', 1))
        with self.assertRaises(ValueError): self.seal()

    def test_wrong_actual_variable_dtype(self):
        next(n for n in self.tree['children'] if n.get('name') == 'state')['dtypep'] = '0x2'
        self.ast.write_text(json.dumps(self.tree))
        with self.assertRaises(ValueError): self.seal()

    def test_wrong_enum_source(self):
        self.tree['children'][0]['itemsp'][0]['loc'] = '/other/core.sv,1:1,1:9'
        self.ast.write_text(json.dumps(self.tree))
        with self.assertRaises(ValueError): self.seal()

    def test_unresolved_enum(self):
        self.tree['children'][0]['itemsp'][0]['valuep'] = []
        self.ast.write_text(json.dumps(self.tree))
        with self.assertRaises(ValueError): self.seal()

    def test_aliased_fsm(self):
        self.tree['children'][0]['itemsp'][1]['valuep'][0]['name'] = "7'h3"
        self.ast.write_text(json.dumps(self.tree))
        with self.assertRaises(ValueError): self.seal()

    def test_altered_receipt_ids(self):
        receipt = self.seal()
        receipt['mapping']['S_PIPE'] += 1
        with self.assertRaises(ValueError): proof.validate(receipt)

    def test_altered_generated_output(self):
        receipt = self.seal()
        self.cpp.write_text('different model')
        with self.assertRaises(ValueError): proof.validate(receipt)

    def test_unlisted_ast(self):
        alien = self.model/'Vventium_top_099_width.tree.json'
        alien.write_text(self.ast.read_text())
        with self.assertRaises(ValueError): proof.seal(self.before, self.vf, alien)

    def test_stale_ast(self):
        os.utime(self.ast, ns=(1, 1))
        with self.assertRaises(ValueError): self.seal()


def fixture(mode='nc-isolated', fast=False):
    spec = {'schema': 1, 'target_pc': 0x8000, 'mode': mode, 'operations': [
        {'width': 2, 'physical_bytes': [0xfff, 0x2000], 'linear_bytes': [0x4fff, 0x5000],
         'axi_bytes': [0x100fff, 0x102000], 'require_fast': fast}]}
    rows = [{'type': 'begin', 'schema': 1, 'profile_sha256': PROFILE, 'target_pc': 0x8000,
             'expected_reads': 1, 'has_consumer': 0, 'consumer_pc': 0, 'load_state': 3,
             'exec_state': 5, 'pipe_state': 28, 'walk_state': 40, 'ext_kind': 5}]

    def transaction(cycle, tid, address, size, length, narrow):
        ar = {'cycle': cycle, 'address': address, 'id': 0, 'size': size, 'len': length,
              'burst': 1, 'narrow': narrow}
        rows.append(dict(ar, type='axi_ar_offer', accepted=1))
        rows.append(dict(ar, type='axi_ar', transaction=tid))
        for i in range(length+1):
            rows.append({'type': 'axi_r', 'cycle': cycle+1+i, 'transaction': tid,
                         'id': 0, 'resp': 0, 'data': 0, 'last': int(i == length), 'narrow': narrow})
    transaction(1, 1, 0x8000, 2, 7, 0)  # legal unrelated instruction cache linefill
    if mode == 'nc-isolated':
        transaction(12, 2, 0x100fff, 0, 0, 1)
        transaction(14, 3, 0x102000, 0, 0, 1)
    base = {'type': 'core', 'owner': 'pipe-held' if fast else 'slow-ext', 'owner_pc': 0x8000,
            'state': 28 if fast else 3, 'walk': 0, 'walk_return': 3, 'req': 1, 'we': 0,
            'strobes': 1, 'extent': 2, 'beat_ack': 1, 'accepted': 1, 'final_ack': 1,
            'final_read': 0, 'pipe_commit': 0, 'fsm_enabled': 1, 'pipe_active': int(fast),
            'xp_cross': int(not fast), 'xp_pending': 0}
    rows.append(dict(base, cycle=11, physical=0xfff, linear=0x4fff, beat_ack=0, accepted=0, final_ack=0))
    rows.append(dict(base, cycle=12, physical=0xfff, linear=0x4fff))
    rows.append(dict(base, cycle=13, state=40, walk=1, walk_return=28 if fast else 3,
                     physical=0xdead, linear=0xdead))
    rows.append(dict(base, cycle=16, physical=0x2000, linear=0x5000, final_read=1,
                     xp_pending=1, pipe_commit=int(fast)))
    rows[1:] = sorted(rows[1:], key=lambda r: r['cycle'])
    rows.append({'type': 'complete', 'records': len(rows)+1, 'last_cycle': 18, 'final_reads': 1,
                 'fast_commits': int(fast), 'axi_reads': 3 if mode == 'nc-isolated' else 1,
                 'axi_beats': 10 if mode == 'nc-isolated' else 8})
    return rows, spec, [16 if fast else 17]


class GeometryTests(unittest.TestCase):
    def test_positive_scopes(self):
        for mode in ('nc-isolated', 'ram'):
            for fast in (False, True):
                rows, spec, clocks = fixture(mode, fast)
                result = check(rows, spec, MAPPING, PROFILE, clocks)
                self.assertEqual(result['operands'], 1)
                self.assertEqual(result['fast_commits'], int(fast))

    def test_single_nc_byte_lanes_and_aligned_words(self):
        for width, lane in [(1, x) for x in range(4)] + [(2, 0), (2, 2)]:
            rows, spec, clocks = fixture(fast=True)
            physical, linear, axi = 0x3000+lane, 0x7000+lane, 0x103000+lane
            op = spec['operations'][0]
            op.update(width=width, physical_bytes=list(range(physical, physical+width)),
                      linear_bytes=list(range(linear, linear+width)), axi_bytes=list(range(axi, axi+width)))
            rows = [r for r in rows if not (r['type']=='core' and r['cycle'] in (12, 13)) and
                    not (r['type'].startswith('axi_') and r.get('narrow') and r['cycle'] in (12, 13))]
            for r in rows:
                if r['type']=='core':
                    r.update(physical=physical, linear=linear, strobes=(1 << width)-1, extent=width, xp_cross=0)
                if r['type'] in ('axi_ar', 'axi_ar_offer') and r.get('narrow'):
                    r.update(address=axi, size=width-1)
                if r.get('transaction')==3: r['transaction']=2
            rows[-1].update(records=len(rows), axi_reads=2, axi_beats=9)
            self.assertEqual(check(rows, spec, MAPPING, PROFILE, clocks)['nc_transactions'], 1)

    def test_negative_mutations(self):
        mutations = {
            'profile': lambda r,s,c: r[0].update(profile_sha256='b'*64),
            'fsm': lambda r,s,c: r[0].update(pipe_state=27),
            'truncation': lambda r,s,c: r.pop(),
            'overflow': lambda r,s,c: r.insert(1, {'type': 'error', 'reason': 'overflow'}),
            'empty-oracle': lambda r,s,c: s.update(operations=[]),
            'no-fast': lambda r,s,c: s['operations'][0].update(require_fast=True),
            'wrong-retirement': lambda r,s,c: c.__setitem__(0, 13),
            'widened-core': lambda r,s,c: next(x for x in r if x['type']=='core').update(strobes=15),
            'chain': lambda r,s,c: next(x for x in r if x['type']=='core').update(chain_accept=1),
            'rresp': lambda r,s,c: next(x for x in r if x['type']=='axi_r').update(resp=2),
            'fill-width': lambda r,s,c: next(x for x in r if x['type']=='axi_ar').update(size=1),
            'wrong-nc': lambda r,s,c: s['operations'][0]['axi_bytes'].__setitem__(0, 0x100ffe),
            'wrong-core': lambda r,s,c: s['operations'][0]['physical_bytes'].__setitem__(0, 0xffe),
            'wrong-linear': lambda r,s,c: s['operations'][0]['linear_bytes'].__setitem__(0, 0x4ffe),
            'wrong-owner': lambda r,s,c: next(x for x in r if x['type']=='core').update(owner='chain-next'),
            'missing-accepted': lambda r,s,c: next(x for x in r if x['type']=='core' and x['accepted']).update(accepted=0),
            'write': lambda r,s,c: next(x for x in r if x['type']=='core').update(we=1),
            'missing-ar': lambda r,s,c: next(x for x in r if x['type']=='axi_ar_offer').update(accepted=0),
            'last': lambda r,s,c: next(x for x in r if x['type']=='axi_r').update(last=1),
            'extra-nc': lambda r,s,c: s.update(mode='ram'),
            'early-final': lambda r,s,c: next(x for x in r if x['type']=='core' and x['final_read']).update(cycle=14),
        }
        for name, mutation in mutations.items():
            with self.subTest(name=name):
                rows, spec, clocks = fixture()
                mutation(rows, spec, clocks)
                with self.assertRaises(ValueError): check(rows, spec, MAPPING, PROFILE, clocks)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.out:
        args.out.mkdir(parents=True, exist_ok=False)
        out = args.out
    else:
        out = Path(tempfile.mkdtemp(prefix='ventium-memory-geometry-qualification.'))
    with (out/'tests.log').open('x') as stream:
        result = unittest.TextTestRunner(stream=stream, verbosity=2).run(
            unittest.defaultTestLoader.loadTestsFromModule(__import__(__name__)))
    proof.write_new(out/'receipt.json', {'host_only': True, 'tests_run': result.testsRun,
                    'success': result.wasSuccessful(), 'source_sha256': {
                        p.name: proof.sha(p) for p in [Path(__file__), Path(proof.__file__),
                                                     Path(__file__).with_name('check_memory_geometry.py')]}})
    print(out)
    print((out/'tests.log').read_text())
    raise SystemExit(0 if result.wasSuccessful() else 1)
