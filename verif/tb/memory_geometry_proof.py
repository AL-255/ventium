#!/usr/bin/env python3
"""Fail-closed, host-only begin/seal/bind proof for a FUTURE fresh elaboration.

Never invokes Verilator. Uses its same-invocation width.tree.json enum values,
not current-source enum numbering. See MEMORY_GEOMETRY_PROBE.md for lifecycle.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import time


def require(ok, message):
    if not ok:
        raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def write_new(path, value):
    with Path(path).open('x') as f:
        json.dump(value, f, indent=2, sort_keys=True)
        f.write('\n')


def fingerprint(path):
    p = Path(path).resolve(strict=True)
    before = p.stat()
    result = {'sha256': sha(p), 'size': before.st_size, 'inode': before.st_ino,
              'mtime_ns': before.st_mtime_ns, 'ctime_ns': before.st_ctime_ns}
    require(before == p.stat(), f'file changed while hashing: {p}')
    return result


def begin(config):
    """Config: cwd, argv (without executable), model_dir, sources, roles, version.

    sources is an explicit anticipated superset of Verilator S dependencies,
    including compiler binary, standard RTL, filelists and host observer files.
    Its completeness is checked AGAINST compiler S records at seal time.
    """
    c = dict(config)
    c['cwd'] = str(Path(c['cwd']).resolve(strict=True))
    c['model_dir'] = str(Path(c['model_dir']).resolve())
    require(not Path(c['model_dir']).exists(), 'model directory already exists; no retrofit')
    a = c['argv']
    require('--cc' in a and '--build' not in a, 'separate fresh C++ generation from link')
    require('--dump-tree-json' in a and '--json-only' not in a, 'same C++ elaboration must retain AST')
    require('--no-json-ids' in a and '--json-ids' not in a, 'literal compiler source locations required')
    require('-Mdir' in a and a.count('-Mdir') == 1, 'one explicit -Mdir required')
    md = Path(c['cwd']) / a[a.index('-Mdir') + 1]
    require(str(md.resolve()) == c['model_dir'], '-Mdir mismatch')
    require(c['version'].startswith('Verilator 5.046'), 'unsupported compiler AST schema')
    require(not any('\n' in x or '"' in x or "'" in x for x in a), 'unsupported quoted argv')
    sources = {str(Path(p).resolve(strict=True)): fingerprint(p) for p in c['sources']}
    roles = {k: str(Path(v).resolve(strict=True)) for k, v in c['roles'].items()}
    require(set(roles) == {'core', 'kind', 'top', 'bus', 'adapter', 'observer', 'compiler'}, 'missing source roles')
    require(set(roles.values()) <= sources.keys(), 'role missing from pre-elaboration coverage')
    return {'schema': 1, 'started_ns': time.time_ns(), 'cwd': c['cwd'],
            'model_dir': c['model_dir'], 'argv': a, 'version': c['version'],
            'sources': sources, 'roles': roles}


def records(path, cwd):
    command = None
    sources, outputs = {}, {}
    for line in Path(path).read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        cols = shlex.split(line)
        if cols[0] == 'C':
            require(command is None and len(cols) == 2, 'duplicate/malformed command')
            command = cols[1]
            continue
        require(cols[0] in ('S', 'T') and len(cols) == 9, 'unknown verFiles record')
        p = str((Path(cwd) / cols[8]).resolve(strict=True))
        target = sources if cols[0] == 'S' else outputs
        require(p not in target, 'duplicate source/output')
        target[p] = {'size': int(cols[1]), 'inode': int(cols[2]),
                     'ctime_ns': int(cols[3])*10**9 + int(cols[4]),
                     'mtime_ns': int(cols[5])*10**9 + int(cols[6])}
    require(command and sources and outputs, 'incomplete verFiles')
    return command, sources, outputs


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


def enum_map(tree, roles, cwd):
    """Parse real Verilator 5.046 Ast dump schema, only resolved CONST values."""
    all_nodes = list(nodes(tree))
    by_addr = {n['addr']: n for n in all_nodes if n.get('addr')}

    def source_is(location, role):
        # The compiler may retain relative paths or a workspace symlink in
        # literal locations. Compare the actual source file, just as begin()
        # and the compiler dependency records do; never match by basename.
        match = re.fullmatch(r'(.+),\d+:\d+,\d+:\d+', location)
        if match is None:
            return False
        try:
            return str((Path(cwd) / match[1]).resolve(strict=True)) == roles[role]
        except (OSError, RuntimeError):
            return False

    def resolved_dtype(addr):
        visited = set()
        while addr in by_addr and by_addr[addr].get('type') == 'REFDTYPE':
            require(addr not in visited, 'cyclic compiler dtype reference')
            visited.add(addr)
            addr = by_addr[addr].get('refDTypep')
        return addr
    result = {}
    for names, role, variables in [
            (('S_LOAD', 'S_EXEC', 'S_PIPE', 'S_WALK'), 'core', ('state', 'walk_ret_state')),
            (('K_EXT',), 'kind', ('q_kind',))]:
        matches = []
        for n in all_nodes:
            if n.get('type') != 'ENUMDTYPE':
                continue
            items = n.get('itemsp', [])
            if set(names) <= {x.get('name') for x in items}:
                matches.append(n)
        require(len(matches) == 1, 'missing/ambiguous compiler enum dtype')
        dtype = matches[0]
        for name in names:
            items = [x for x in dtype['itemsp'] if x.get('name') == name]
            require(len(items) == 1, 'duplicate enum item')
            item = items[0]
            require(item.get('type') == 'ENUMITEM' and
                    source_is(item.get('loc', ''), role), 'enum source identity mismatch')
            value = item.get('valuep', [])
            require(len(value) == 1 and value[0].get('type') == 'CONST', 'unresolved enum value')
            m = re.fullmatch(r"(\d+)'([hbd])([0-9a-fA-F]+)", value[0].get('name', ''))
            require(m is not None, 'unsupported compiler constant')
            result[name] = int(m[3], {'h': 16, 'b': 2, 'd': 10}[m[2]])
        for name in variables:
            found = [n for n in all_nodes if n.get('type') == 'VAR' and n.get('name') == name
                     and source_is(n.get('loc', ''), 'core')]
            require(len(found) == 1 and resolved_dtype(found[0].get('dtypep')) == dtype.get('addr')
                    and dtype.get('addr'), 'actual state/kind variable dtype mismatch')
    ids = [result[k] for k in ('S_LOAD', 'S_EXEC', 'S_PIPE', 'S_WALK')]
    require(len(set(ids)) == 4 and all(0 <= x < 128 for x in ids) and
            0 <= result['K_EXT'] < 32, 'invalid compiler enum IDs')
    return result


def seal(before, verfiles, ast):
    require(before['schema'] == 1, 'unsupported begin schema')
    for p, expected in before['sources'].items():
        require(fingerprint(p) == expected, f'stale/changed source: {p}')
    command, inputs, outputs = records(verfiles, before['cwd'])
    require(command == ' '.join(before['argv']), 'compiler command mismatch')
    require(inputs.keys() <= before['sources'].keys(), 'compiler discovered uncovered source')
    for p, stats in inputs.items():
        require(all(before['sources'][p][k] == v for k, v in stats.items()), 'source stat mismatch')
    require({before['roles'][x] for x in ('core', 'kind', 'top', 'bus', 'compiler')} <= inputs.keys(),
            'required model source not compiled')
    model = Path(before['model_dir'])
    ast = str(Path(ast).resolve(strict=True))
    require(ast in outputs and Path(ast).name.endswith('_width.tree.json'), 'AST is not same-invocation width output')
    generated = {}
    for p in outputs:
        require(Path(p).is_relative_to(model), 'output outside fresh model directory')
        require(Path(p).stat().st_mtime_ns >= before['started_ns'], 'stale generated output')
        generated[p] = sha(p)
    require(any(p.endswith('.cpp') for p in generated), 'missing C++ model output')
    mapping = enum_map(load(ast), before['roles'], before['cwd'])
    return {'schema': 1, 'begin': before, 'verfiles': str(Path(verfiles).resolve()),
            'verfiles_sha256': sha(verfiles), 'ast': ast, 'mapping': mapping, 'generated': generated}


def validate(receipt):
    require(receipt['schema'] == 1, 'unsupported receipt schema')
    require(sha(receipt['verfiles']) == receipt['verfiles_sha256'], 'changed compiler dependency record')
    for p, h in receipt['generated'].items():
        require(sha(p) == h, 'changed generated output')
    # Re-sealing rechecks complete dependency coverage, command and AST mapping.
    require(seal(receipt['begin'], receipt['verfiles'], receipt['ast']) == receipt, 'proof mismatch')
    return digest(receipt)


def header(receipt):
    h = validate(receipt)
    m = receipt['mapping']
    values = ','.join(str(m[x]) for x in ('S_LOAD', 'S_EXEC', 'S_PIPE', 'S_WALK', 'K_EXT'))
    return '#pragma once\n#include "memory_geometry_probe.h"\n' + \
        'inline MemoryGeometryStates ventium_memory_geometry_model_states() {\n' + \
        f'    return {{{values},"{h}"}};\n}}\n'


def bind(receipt, binary, map_header):
    require(Path(map_header).read_text() == header(receipt), 'map header mismatch')
    # A relinked model using this header must carry the exact profile string.
    # The final executable hash then detects later substitution. This is an
    # operational build receipt, not protection against a malicious compiler.
    require(digest(receipt).encode() in Path(binary).read_bytes(), 'binary lacks compiled profile marker')
    return {'schema': 1, 'profile_sha256': validate(receipt),
            'binary': str(Path(binary).resolve(strict=True)), 'binary_sha256': sha(binary),
            'header': str(Path(map_header).resolve(strict=True)), 'header_sha256': sha(map_header)}


def verify_binding(receipt, binding, binary):
    require(binding == bind(receipt, binary, binding['header']), 'binary/profile binding mismatch')
    return binding['profile_sha256']


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['begin', 'seal', 'bind', 'verify'])
    p.add_argument('--input', type=Path, required=True)
    p.add_argument('--out', type=Path)
    p.add_argument('--verfiles', type=Path)
    p.add_argument('--ast', type=Path)
    p.add_argument('--header', type=Path)
    p.add_argument('--binary', type=Path)
    p.add_argument('--binding', type=Path)
    a = p.parse_args()
    item = load(a.input)
    if a.action == 'begin': result = begin(item)
    elif a.action == 'seal':
        result = seal(item, a.verfiles, a.ast)
        with a.header.open('x') as f: f.write(header(result))
    elif a.action == 'bind': result = bind(item, a.binary, a.header)
    else:
        print(verify_binding(item, load(a.binding), a.binary))
        return
    write_new(a.out, result)


if __name__ == '__main__':
    main()
