#!/usr/bin/env python3
"""Read existing performance counters from an unchanged running SoC simulator.

Prepare a layout against that model's generated headers as an ordinary user.
Read uses only /proc/PID/mem opened O_RDONLY: no ptrace, signals, debugger
commands, clock steps or writes to the guest. Linux may require administrator
access for an unrelated process. Never change ptrace policy for this tool.

These opportunistic snapshots are diagnostic, not architectural traces or
standard-suite acceptance. A simulation-clock bracket and counter invariants
bound/reject torn samples. Asynchronously updated families can differ within
that explicitly recorded bracket (at most 16 clocks); this is not an atomic
state dump. Use clock-boundary logs and rendered frames for official IPC.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time

CORE = 'system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__'
L1 = 'system__DOT__u_cpu__DOT__u_core__DOT__u_l1axi__DOT__u_l1d__DOT__'
L2 = 'system__DOT__cache__DOT__l2p_'
LIMIT = 8 * 1024 * 1024


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def counter_fields(header):
    fields = {}
    for line in header.splitlines():
        match = re.fullmatch(r'\s*(QData/\*63:0\*/|VlUnpacked<QData/\*63:0\*/, (\d+)>) '
                             r'([A-Za-z0-9_]+);', line)
        if not match:
            continue
        _, count, member = match.groups()
        if member.startswith(CORE + 'pp_'):
            name = member[len(CORE):]
        elif member.startswith(L1 + 'perf_'):
            name = 'l1_' + member[len(L1):]
        elif member.startswith(L2):
            name = 'l2_' + member[len(L2):]
        else:
            continue
        if name == 'pp_fp_stream_cycle':
            continue  # FIFO timestamps, not cumulative counters.
        if name in fields:
            raise ValueError('duplicate counter')
        fields[name] = (member, int(count) if count else 1, count is not None)
    if not {'pp_cycles', 'pp_ret1', 'pp_ret2', 'pp_state'} <= fields.keys():
        raise ValueError('required core profiler is absent')
    return fields


def check_layout(layout):
    if layout['schema'] != 1 or layout['byteorder'] != 'little':
        raise ValueError('unsupported layout')
    if not 0 < layout['root_size'] <= LIMIT or not 0 <= layout['rootp_offset'] < 65536:
        raise ValueError('invalid root size/pointer offset')
    for name, field in layout['fields'].items():
        offset, count = field['offset'], field['count']
        if not re.fullmatch(r'(pp_|l1_perf_|l2_)[a-z0-9_]+', name):
            raise ValueError('not a performance counter')
        if not (0 <= offset and 0 < count <= 4096 and
                offset + count * 8 <= layout['root_size']):
            raise ValueError('counter outside generated root')
    if not layout['fields']:
        raise ValueError('empty counter layout')
    for name, offset in layout.get('board_fields', {}).items():
        if name not in {'board_aw_count', 'board_w_count', 'board_b_count',
                        'board_ar_count', 'board_r_count'} or not 0 <= offset <= 4096:
            raise ValueError('invalid board counter')


def prepare(args):
    obj = args.obj.resolve(strict=True)
    binary = args.binary.resolve(strict=True)
    out = args.out.resolve(); out.mkdir()
    header = obj / 'Vsystem___024root.h'
    fields = counter_fields(header.read_text())
    makefile = (obj / 'Vsystem.mk').read_text()
    vroot = Path(re.search(r'^VERILATOR_ROOT = (.+)$', makefile, re.M)[1])
    symbols = subprocess.check_output(['nm', '-C', str(binary)], text=True)
    required = {}
    board_header = getattr(args, 'board_header', None)
    for name in (('top', 'main_time', 'board_memory') if board_header else ('top', 'main_time')):
        matches = re.findall(r'^([0-9a-f]+) [bB] ' + name + '$', symbols, re.M)
        if len(matches) != 1:
            raise ValueError('missing/ambiguous native symbol: ' + name)
        required[name] = int(matches[0], 16)
    with binary.open('rb') as stream:
        elf = stream.read(20)
    if elf[:6] != b'\x7fELF\x02\x01':
        raise ValueError('only little-endian ELF64 is supported')
    elf_type = struct.unpack_from('<H', elf, 16)[0]
    if elf_type not in (2, 3):
        raise ValueError('unsupported ELF type')
    source = out / 'counter_offsets.cpp'
    lines = ['#include "Vsystem.h"', '#include "Vsystem___024root.h"',
             '#include <cstddef>', '#include <cstdio>', 'int main() {',
             'std::printf("root_size %zu\\nrootp_offset %zu\\n", '
             'sizeof(Vsystem___024root), offsetof(Vsystem, rootp));']
    for name, (member, count, _) in fields.items():
        lines.append(f'static_assert(sizeof(((Vsystem___024root*)0)->{member}) == {count}*8);')
        lines.append(f'std::printf("{name} %zu\\n", offsetof(Vsystem___024root, {member}));')
    if board_header:
        board_header = board_header.resolve(strict=True)
        lines.insert(0, '#include ' + json.dumps(str(board_header)))
        for member in ('aw_count', 'w_count', 'b_count', 'ar_count', 'r_count'):
            lines.append(f'static_assert(sizeof(((ven_board::AxiMemory*)0)->{member}) == 8);')
            lines.append(f'std::printf("board_{member} %zu\\n", offsetof(ven_board::AxiMemory, {member}));')
    source.write_text('\n'.join(lines + ['}']) + '\n')
    helper = out / 'counter_offsets'
    command = ['g++', '-std=c++17', '-O0', '-I' + str(obj),
               '-I' + str(vroot / 'include'), '-I' + str(vroot / 'include/vltstd'),
               '-MMD', '-MF', str(out / 'counter_offsets.d'), str(source), '-o', str(helper)]
    with (out / 'compile.log').open('xb') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
    values = {k: int(v) for k, v in (line.split() for line in
              subprocess.check_output([str(helper)], text=True).splitlines())}
    deps = (out / 'counter_offsets.d').read_text().replace('\\\n', ' ').split(':', 1)[1].split()
    dependencies = [Path(p).resolve(strict=True) for p in deps]
    if header not in dependencies or obj / 'Vsystem.h' not in dependencies:
        raise ValueError('layout compiler did not use model-local headers')
    layout = dict(schema=1, byteorder=sys.byteorder, elf_type=elf_type,
                  binary=str(binary), binary_sha256=sha(binary), symbols=required,
                  root_size=values.pop('root_size'), rootp_offset=values.pop('rootp_offset'),
                  fields={name: dict(offset=values[name], count=value[1], array=value[2])
                          for name, value in fields.items()}, command=command,
                  board_fields={k:v for k,v in values.items() if k.startswith('board_')},
                  pins={str(p): sha(p) for p in (*dependencies,
                        obj / 'Vsystem.mk', source, helper, out / 'counter_offsets.d')})
    check_layout(layout)
    with (out / 'layout.json').open('x') as stream:
        json.dump(layout, stream, indent=2)
    print(json.dumps(dict(layout=str(out / 'layout.json'), counters=len(fields),
                          model_sha256=layout['binary_sha256'])))


def read_exact(fd, size, address):
    value = os.pread(fd, size, address)
    if len(value) != size:
        raise ValueError('short process-memory read')
    return value


def decode(blob, first, fields):
    result = {}
    for name, field in fields.items():
        values = struct.unpack_from('<' + 'Q' * field['count'], blob, field['offset'] - first)
        result[name] = list(values) if field['array'] else values[0]
    return result


def validate(counters):
    clocks = counters['pp_cycles']
    if sum(counters['pp_state']) != clocks:
        raise ValueError('torn core state partition')
    if not 0 <= counters['pp_ret2'] <= counters['pp_ret1'] <= clocks:
        raise ValueError('invalid retirement counters')
    for whole, wait, ack in (('pp_state', 'pp_mem_wait', 'pp_mem_ack'),
                            ('pp_slow_load_kind', 'pp_slow_load_wait_kind', 'pp_slow_load_ack_kind'),
                            ('pp_slow_store_kind', 'pp_slow_store_wait_kind', 'pp_slow_store_ack_kind')):
        if all(k in counters for k in (whole, wait, ack)):
            arrays = [counters[k] for k in (whole, wait, ack)]
            if len({len(a) for a in arrays}) != 1 or any(w + a > n for n, w, a in zip(*arrays)):
                raise ValueError('torn wait/ack partition')
    if 'l1_perf_fill_cycles' in counters:
        if counters['l1_perf_fill_cycles'] != (counters['l1_perf_fill_wait'] + counters['l1_perf_fill_ack']):
            raise ValueError('torn L1 fill partition')
    if 'board_b_count' in counters and (counters['board_b_count'] > min(counters['board_aw_count'],
            counters['board_w_count']) or counters['board_r_count'] > 8*counters['board_ar_count']):
        raise ValueError('torn board response ownership')
    for total, parts in (('l2_read', 'l2_read_burst'),
                         ('l2_lookup_miss', 'l2_miss_burst'),
                         ('l2_lookup_miss', 'l2_miss_start64')):
        if total in counters and parts in counters and counters[total] != sum(counters[parts]):
            raise ValueError('torn L2 request partition')


def identity(pid, expected):
    proc = Path('/proc') / str(pid)
    if proc.joinpath('exe').resolve(strict=True) != Path(expected).resolve(strict=True):
        raise ValueError('native executable mismatch')
    stat = proc.joinpath('stat').read_text().rsplit(')', 1)[1].split()
    return stat[19]  # /proc stat field 22: process start time, not PID alone.


def sample(args):
    layout = json.loads(args.layout.read_text()); check_layout(layout)
    binary = Path(layout['binary'])
    if sha(binary) != layout['binary_sha256'] or any(sha(p) != h for p, h in layout['pins'].items()):
        raise ValueError('native binary/generated layout input drift')
    pid = args.pid
    start = identity(pid, binary)
    if sha(Path('/proc') / str(pid) / 'exe') != layout['binary_sha256']:
        raise ValueError('live executable hash mismatch')
    mappings = (Path('/proc') / str(pid) / 'maps').read_text().splitlines()
    inode = str(binary.stat().st_ino)
    mapped = [line.split() for line in mappings if len(line.split()) >= 6 and
              line.split()[4] == inode and line.split()[2] == '00000000' and
              Path(line.split(maxsplit=5)[5]).resolve() == binary.resolve()]
    if len(mapped) != 1:
        raise ValueError('missing/ambiguous native load mapping')
    bias = int(mapped[0][0].split('-')[0], 16) if layout['elf_type'] == 3 else 0
    fields = layout['fields']
    first = min(f['offset'] for f in fields.values())
    last = max(f['offset'] + 8*f['count'] for f in fields.values())
    ptr = lambda fd, address: struct.unpack('<Q', read_exact(fd, 8, address))[0]
    fd = os.open(f'/proc/{pid}/mem', os.O_RDONLY)
    try:
        top = ptr(fd, bias + layout['symbols']['top'])
        root = ptr(fd, top + layout['rootp_offset'])
        if not top or not root:
            raise ValueError('uninitialized native model')
        for attempt in range(1000):
            cycle_a = ptr(fd, bias + layout['symbols']['main_time'])
            raw_a = read_exact(fd, last-first, root+first)
            board_fields = layout.get('board_fields', {})
            if board_fields:
                board_first = min(board_fields.values()); board_last = max(board_fields.values()) + 8
                raw_board = read_exact(fd, board_last-board_first,
                                      bias+layout['symbols']['board_memory']+board_first)
            cycle_b = ptr(fd, bias + layout['symbols']['main_time'])
            if not 0 <= cycle_b - cycle_a <= 16:
                continue
            a = decode(raw_a, first, fields)
            a.update({k:struct.unpack_from('<Q', raw_board, offset-board_first)[0]
                      for k,offset in board_fields.items()})
            try:
                validate(a)
            except ValueError:
                continue
            break
        else:
            raise ValueError('no consistent passive sample; process was not stopped')
        if identity(pid, binary) != start:
            raise ValueError('process identity changed during read')
    finally:
        os.close(fd)
    result = dict(schema=1, diagnostic_only=True, signals_sent=False, memory_writes=False,
                  pid=pid, process_starttime=start, unix=time.time(),
                  main_time_bracket=[cycle_a, cycle_b], maximum_skew_clocks=cycle_b-cycle_a,
                  model_sha256=layout['binary_sha256'], attempts=attempt+1,
                  layout_sha256=sha(args.layout), counters=a,
                  reader_sha256=sha(__file__),
                  caveat='Passive async sampling; families may differ within clock bracket. Not gameplay acceptance.')
    with args.out.open('x') as stream:
        json.dump(result, stream, indent=2)
    print(json.dumps({k:v for k,v in result.items() if k != 'counters'}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('prepare')
    p.add_argument('--obj', type=Path, required=True)
    p.add_argument('--binary', type=Path, required=True)
    p.add_argument('--board-header', type=Path, help='exact frozen board_axi_memory.h, if linked')
    p.add_argument('--out', type=Path, required=True)
    p = commands.add_parser('read')
    p.add_argument('--layout', type=Path, required=True)
    p.add_argument('--pid', type=int, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    try:
        (prepare if args.command == 'prepare' else sample)(args)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(2, str(error) + '\n')


if __name__ == '__main__':
    main()
