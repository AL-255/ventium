#!/usr/bin/env python3
"""Freeze an explicitly UNQUALIFIED derivative of the pinned RK 40 MHz inputs.

The parent has 179 payloads and 110 hardware defines. Replacements must name
existing frozen paths and explicitly pinned, absolute regular files below
declared source roots. The optional reviewed FE-DTLB permission experiment adds
exactly one pinned source and three definitions, never a discovered file/glob.
There is no accepted-model inference, Vivado invocation, or prior-run mutation.

An error leaves an incomplete output for inspection; it never publishes the
input manifest before all source/destination stability checks have passed.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat


class FreezeError(RuntimeError):
    pass


FE_SOURCE = 'ventium/rtl/core/ven_fe_dtlb.sv'
FE_DEFINES = ['VEN_FE_PIPE', 'VEN_FE_DTLB_MULTI', 'VEN_FE_DTLB_PERM']


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def checked_sha(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value):
        raise FreezeError(f'invalid SHA-256: {value!r}')
    return value


def absolute_path(value):
    if not isinstance(value, str):
        raise FreezeError('paths must be strings')
    path = Path(value)
    # pathlib preserves POSIX's special '//' anchor, while open_plain walks
    # from '/'. Reject that alias so lexical containment matches actual opens.
    if not path.is_absolute() or path.anchor != '/' or str(path) != value:
        raise FreezeError(f'expected a canonical absolute path: {value!r}')
    if '..' in path.parts:
        raise FreezeError(f'path traversal is forbidden: {value!r}')
    return path


def frozen_path(value):
    if not isinstance(value, str) or not value or '\\' in value:
        raise FreezeError(f'invalid frozen relative path: {value!r}')
    path = PurePosixPath(value)
    if path.is_absolute() or str(path) != value or any(x in ('.', '..') for x in path.parts):
        raise FreezeError(f'noncanonical or escaping frozen path: {value!r}')
    return value


def open_plain(path, directory=False, create=False):
    """Open every path component with O_NOFOLLOW, including ancestor directories."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open('/', flags)
    try:
        for part in path.parts[1:-1]:
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        # Nonblocking open ensures an unexpected FIFO cannot hang before fstat
        # rejects its non-regular type. It does not affect regular-file reads.
        final_flags = flags if directory else os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        if create:
            final_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        result = os.open(path.name, final_flags, 0o644, dir_fd=fd)
        mode = os.fstat(result).st_mode
        if not (stat.S_ISDIR(mode) if directory else stat.S_ISREG(mode)):
            os.close(result)
            raise FreezeError(f'not a plain {"directory" if directory else "file"}: {path}')
        return result
    finally:
        os.close(fd)


def directory(path):
    if path == Path('/'):
        raise FreezeError('a filesystem root is not a permitted task directory')
    fd = open_plain(path, directory=True)
    try:
        return os.fstat(fd).st_dev, os.fstat(fd).st_ino
    finally:
        os.close(fd)


def fingerprint(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def snapshot(path, expected=None, expected_bytes=None):
    fd = open_plain(path)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if expected_bytes is not None and before.st_size != expected_bytes:
            raise FreezeError(f'byte-count mismatch: {path}')
        data = stream.read()
        after = os.fstat(stream.fileno())
    if fingerprint(before) != fingerprint(after) or len(data) != after.st_size:
        raise FreezeError(f'input changed while reading: {path}')
    digest = sha256(data)
    if expected is not None and digest != expected:
        raise FreezeError(f'SHA-256 mismatch: {path}')
    if expected_bytes is not None and len(data) != expected_bytes:
        raise FreezeError(f'byte-count mismatch: {path}')
    return {'data': data, 'sha256': digest, 'bytes': len(data),
            'fingerprint': fingerprint(after)}


def unchanged(path, before):
    after = snapshot(path, before['sha256'], before['bytes'])
    if after['fingerprint'] != before['fingerprint']:
        raise FreezeError(f'input identity or metadata changed during freeze: {path}')


def write_new(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    directory(path.parent)
    fd = open_plain(path, create=True)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    return snapshot(path, sha256(data), len(data))


def publish_new(path, data):
    # link() gives an atomic no-overwrite publication; both names are in the
    # new task-owned output and the temporary name is removed after publication.
    pending = path.with_name('.' + path.name + '.pending')
    write_new(pending, data)
    fd = open_plain(path.parent, directory=True)
    try:
        os.link(pending.name, path.name, src_dir_fd=fd, dst_dir_fd=fd,
                follow_symlinks=False)
        os.unlink(pending.name, dir_fd=fd)
        os.fsync(fd)
    finally:
        os.close(fd)


def unique_json(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise FreezeError(f'duplicate JSON key: {key!r}')
        result[key] = value
    return result


def pairs(values, label, value_check):
    result = {}
    for value in values:
        if '=' not in value:
            raise FreezeError(f'{label} must be FROZEN_PATH=VALUE')
        name, content = value.split('=', 1)
        frozen_path(name)
        if name in result:
            raise FreezeError(f'duplicate {label}: {name}')
        result[name] = value_check(content)
    return result


def overlaps(a, b):
    return a.is_relative_to(b) or b.is_relative_to(a)


def freeze(args):
    parent = absolute_path(args.parent)
    out = absolute_path(args.out)
    roots = [absolute_path(x) for x in args.source_root]
    if len(set(roots)) != len(roots):
        raise FreezeError('duplicate source root')
    parent_identity = directory(parent)
    out_identity = directory(out)
    root_identities = {root: directory(root) for root in roots}
    if overlaps(out, parent) or any(overlaps(out, root) for root in roots):
        raise FreezeError('output must be outside, and not an ancestor of, parent/source roots')
    if any(out.iterdir()):
        raise FreezeError('output must already exist and be empty')

    manifest_path = parent / 'input-manifest.json'
    parent_manifest = snapshot(manifest_path, checked_sha(args.parent_manifest_sha256))
    manifest = json.loads(parent_manifest['data'], object_pairs_hook=unique_json)
    if not isinstance(manifest, dict) or manifest.get('schema') != 1:
        raise FreezeError('expected schema-1 parent manifest')
    if type(manifest.get('core_mhz')) is not int or manifest['core_mhz'] != 40:
        raise FreezeError('expected the unchanged 40 MHz parent profile')
    defs = manifest.get('hardware_defines')
    additions = ['SYNTHESIS', 'VTM_NO_DPI', 'VEN_ALTSYNCRAM_XPM']
    if (not isinstance(defs, list) or len(defs) != 110 or
            any(not isinstance(x, str) or not re.fullmatch(r'[A-Z][A-Z0-9_]*', x) for x in defs) or
            len(set(defs)) != 110 or defs[-3:] != additions or
            manifest.get('hardware_additions') != additions or
            type(manifest.get('simulator_defines')) is not int or manifest['simulator_defines'] != 107):
        raise FreezeError('expected exactly the ordered 107+3 / 110-define parent profile')
    if any(x in defs for x in ('VEN_CACHE_HALF', 'VEN_IC_NARROWB', 'VEN_UOPCACHE')):
        raise FreezeError('retired/extra cache experiment in parent profile')
    defines_path = parent / 'defines.txt'
    parent_defines = snapshot(defines_path, checked_sha(args.parent_defines_sha256))
    if parent_defines['data'] != ('\n'.join(defs) + '\n').encode():
        raise FreezeError('defines.txt does not exactly match the parent manifest')

    records = manifest.get('files')
    if not isinstance(records, list) or len(records) != 179:
        raise FreezeError('expected exactly 179 parent payload records')
    pinned = {}
    for record in records:
        if not isinstance(record, dict):
            raise FreezeError('invalid parent file record')
        name = frozen_path(record.get('frozen'))
        if name in pinned:
            raise FreezeError(f'duplicate frozen path: {name}')
        if name in ('defines.txt', 'input-manifest.json', 'candidate-delta-manifest.json'):
            raise FreezeError(f'reserved output path in parent payloads: {name}')
        expected = checked_sha(record.get('sha256'))
        size = record.get('bytes')
        if type(size) is not int or size < 0:
            raise FreezeError(f'invalid byte count: {name}')
        pinned[name] = snapshot(parent / name, expected, size)
    for name in pinned:
        if any(str(p) in pinned for p in PurePosixPath(name).parents if str(p) != '.'):
            raise FreezeError(f'payload file/directory collision: {name}')

    replacements = pairs(args.replace, 'replacement', absolute_path)
    replacement_pins = pairs(args.replacement_sha256, 'replacement SHA-256', checked_sha)
    if not replacements or replacements.keys() != replacement_pins.keys():
        raise FreezeError('each explicit replacement requires exactly one explicit SHA-256 pin')
    replacement_data = {}
    for name, source in replacements.items():
        if name not in pinned:
            raise FreezeError(f'unknown replacement frozen path: {name}')
        if not any(source.is_relative_to(root) for root in roots) or source.is_relative_to(parent):
            raise FreezeError(f'replacement outside declared live source roots: {source}')
        replacement_data[name] = snapshot(source, replacement_pins[name])

    # A deliberately narrow extension, not an arbitrary definition/source
    # escape hatch. Keep the original parent shape checks unchanged above.
    fe_source_arg = getattr(args, 'fe_dtlb_source', None)
    fe_sha_arg = getattr(args, 'fe_dtlb_sha256', None)
    extra_sources = {}
    extra_data = {}
    new_defs = list(defs)
    if fe_source_arg is not None or fe_sha_arg is not None:
        if fe_source_arg is None or fe_sha_arg is None:
            raise FreezeError('FE-DTLB source and SHA-256 must be supplied together')
        if any(d in defs for d in FE_DEFINES + ['VEN_PIPE_MEM_CHAIN']):
            raise FreezeError('FE-DTLB extension requires an unextended, non-memory-chain parent')
        required = {'ventium/rtl/core/core.sv', 'ventium/rtl_ven_core.f'}
        if not required.issubset(replacements):
            raise FreezeError('FE-DTLB requires explicit core.sv and rtl_ven_core.f replacements')
        if FE_SOURCE in pinned or any(str(p) in pinned for p in PurePosixPath(FE_SOURCE).parents):
            raise FreezeError('FE-DTLB added source collides with a parent payload')
        source = absolute_path(fe_source_arg)
        if not any(source.is_relative_to(root) for root in roots) or source.is_relative_to(parent):
            raise FreezeError('FE-DTLB source outside declared live source roots')
        extra_sources[FE_SOURCE] = source
        extra_data[FE_SOURCE] = snapshot(source, checked_sha(fe_sha_arg))
        filelist = replacement_data['ventium/rtl_ven_core.f']['data'].decode().splitlines()
        source_line = FE_SOURCE.removeprefix('ventium/')
        if filelist.count(source_line) != 1 or filelist.count('rtl/core/core.sv') != 1:
            raise FreezeError('FE-DTLB filelist must contain exactly one child and one core')
        if filelist.index(source_line) >= filelist.index('rtl/core/core.sv'):
            raise FreezeError('FE-DTLB child must precede the core in its explicit filelist')
        new_defs = defs[:-3] + FE_DEFINES + additions

    # Read/check the complete closure before creating any output payload.
    sources = [(manifest_path, parent_manifest), (defines_path, parent_defines)]
    sources += [(parent / name, data) for name, data in pinned.items()]
    sources += [(source, replacement_data[name]) for name, source in replacements.items()]
    sources += [(source, extra_data[name]) for name, source in extra_sources.items()]
    for path, data in sources:
        unchanged(path, data)
    if directory(parent) != parent_identity or directory(out) != out_identity:
        raise FreezeError('parent/output directory identity changed')
    if any(directory(root) != identity for root, identity in root_identities.items()):
        raise FreezeError('live source-root directory identity changed')
    if any(out.iterdir()):
        raise FreezeError('output ceased to be empty before copying')

    new_records = []
    destinations = []
    delta = []
    for name, parent_data in pinned.items():
        data = replacement_data.get(name, parent_data)
        source = replacements.get(name, parent / name)
        dest = out / name
        copied = write_new(dest, data['data'])
        destinations.append((dest, copied))
        new_records.append({'source': str(source), 'frozen': name,
                            'sha256': data['sha256'], 'bytes': data['bytes'],
                            'parent_sha256': parent_data['sha256'], 'parent_bytes': parent_data['bytes'],
                            'provenance': 'explicit_replacement' if name in replacements else 'parent_payload',
                            'role': 'historical_ancestry_only' if name.startswith('evidence/') else 'candidate_input'})
        if name in replacements:
            delta.append({'frozen': name, 'source': str(source),
                          'parent_sha256': parent_data['sha256'], 'parent_bytes': parent_data['bytes'],
                          'candidate_sha256': data['sha256'], 'candidate_bytes': data['bytes']})
    for name, source in extra_sources.items():
        data = extra_data[name]
        dest = out / name
        destinations.append((dest, write_new(dest, data['data'])))
        new_records.append({'source': str(source), 'frozen': name,
                            'sha256': data['sha256'], 'bytes': data['bytes'],
                            'parent_sha256': None, 'parent_bytes': None,
                            'provenance': 'explicit_fe_dtlb_addition', 'role': 'candidate_input'})
    new_define_bytes = ('\n'.join(new_defs) + '\n').encode()
    destinations.append((out / 'defines.txt', write_new(out / 'defines.txt', new_define_bytes)))
    # Fail closed on later source edits, inode replacement, destination edits,
    # symlink replacement, or directory replacement. No acceptance is inferred.
    for path, data in sources + destinations:
        unchanged(path, data)
    if directory(parent) != parent_identity or directory(out) != out_identity:
        raise FreezeError('parent/output directory identity changed after copying')
    if any(directory(root) != identity for root, identity in root_identities.items()):
        raise FreezeError('live source-root directory identity changed after copying')

    note = ('UNQUALIFIED explicit derivative freeze. Parent model identity, receipts and '
            'copied evidence are historical ancestry only. No candidate simulation, '
            'standard-suite, timing, routing, bitstream, deployment or gameplay acceptance is inherited.')
    new_manifest = {'schema': 1, 'qualification': 'UNQUALIFIED',
                    'model_profile': None, 'model_sha256': None, 'current_model_identity': None,
                    'simulator_defines': len(new_defs) - 3, 'hardware_additions': additions,
                    'hardware_defines': new_defs, 'core_mhz': 40, 'profile_note': note,
                    'parent_ancestry': {'directory': str(parent),
                                        'manifest_sha256': parent_manifest['sha256'],
                                        'defines_sha256': parent_defines['sha256'],
                                        'model_profile': manifest.get('model_profile'),
                                        'model_sha256': manifest.get('model_sha256'),
                                        'qualification': manifest.get('qualification'),
                                        'profile_note': manifest.get('profile_note')},
                    'files': new_records}
    new_bytes = (json.dumps(new_manifest, indent=2) + '\n').encode()
    receipt = {'schema': 1, 'kind': 'ventium-fpga-unqualified-derivative-freeze',
               'qualification': 'UNQUALIFIED', 'profile_note': note,
               'parent_directory': str(parent), 'parent_manifest_sha256': parent_manifest['sha256'],
               'parent_defines_sha256': parent_defines['sha256'],
               'frozen_files': len(new_records), 'unchanged_files': 179 - len(replacements),
               'replacement_files': len(replacements), 'core_mhz': 40,
               'added_files': len(extra_sources),
               'added_defines': FE_DEFINES if extra_sources else [],
               'source_additions': [record for record in new_records
                                    if record['provenance'] == 'explicit_fe_dtlb_addition'],
               'hardware_define_count': len(new_defs), 'hardware_defines_sha256': sha256(new_define_bytes),
               'manifest_sha256': sha256(new_bytes), 'source_roots': [str(x) for x in roots],
               'replacements': delta}
    receipt_bytes = (json.dumps(receipt, indent=2) + '\n').encode()
    publish_new(out / 'candidate-delta-manifest.json', receipt_bytes)
    publish_new(out / 'input-manifest.json', new_bytes)
    # Recheck committed records as well; callers must require native exit zero.
    snapshot(out / 'input-manifest.json', sha256(new_bytes), len(new_bytes))
    snapshot(out / 'candidate-delta-manifest.json', sha256(receipt_bytes), len(receipt_bytes))
    for path, data in sources + destinations:
        unchanged(path, data)
    return {'qualification': 'UNQUALIFIED', 'frozen_files': len(new_records),
            'unchanged_files': 179 - len(replacements), 'replacement_files': len(replacements),
            'added_files': len(extra_sources),
            'defines': len(new_defs), 'defines_sha256': sha256(new_define_bytes),
            'manifest_sha256': sha256(new_bytes), 'delta_manifest_sha256': sha256(receipt_bytes),
            'out': str(out)}


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument('--parent', required=True)
    result.add_argument('--parent-manifest-sha256', required=True)
    result.add_argument('--parent-defines-sha256', required=True)
    result.add_argument('--source-root', action='append', required=True)
    result.add_argument('--replace', action='append', required=True,
                        metavar='FROZEN_PATH=ABSOLUTE_SOURCE')
    result.add_argument('--replacement-sha256', action='append', required=True,
                        metavar='FROZEN_PATH=SHA256')
    result.add_argument('--fe-dtlb-source',
                        help='explicit experimental ven_fe_dtlb.sv; adds exactly FE_PIPE/MULTI/PERM')
    result.add_argument('--fe-dtlb-sha256', help='required SHA-256 for --fe-dtlb-source')
    result.add_argument('--out', required=True)
    return result


def main():
    args = parser().parse_args()
    try:
        result = freeze(args)
    except (FreezeError, OSError, ValueError, TypeError, KeyError) as error:
        raise SystemExit(f'candidate freeze refused: {error}') from error
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
