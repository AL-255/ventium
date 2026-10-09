#!/usr/bin/env python3
"""Opt-in, nonarchitectural exit observation for a PRIVATE QEMU 8.2.2 copy.

Do not apply to the pinned oracle in place. This only exposes the live CPU to
the existing gdbstub before process destruction; it never constructs registers
or changes syscall results, traces, RTL, or comparator rules.
"""
from pathlib import Path
import argparse
import hashlib
import json


INCLUDE = '#include "qemu.h"\n'
ENTRY = 'static abi_long do_syscall1(CPUArchState *cpu_env, int num, abi_long arg1,'
EXIT = '        preexit_cleanup(cpu_env, arg1);\n'
HELPER = '''/* Ventium verification-only observation, disabled unless explicitly enabled.
 * INT's actual CPU state is already materialized by cpu_loop. A returning
 * syscall gets a normal single-step stop, but process exit destroys the CPU
 * before that stop. Expose its LIVE state without completing a fake syscall
 * or modifying registers. The ordinary cleanup/exit path still follows.
 * gdb_handlesig is a no-op when no debugger is attached. This is deliberately
 * only before process exit/exit_group, not individual thread teardown or faults.
 */
static void vtm_gdb_preexit(CPUState *cpu)
{
    const char *enabled = getenv("VTM_QEMU_GDB_PREEXIT");

    if (enabled && strcmp(enabled, "1") == 0) {
        (void)gdb_handlesig(cpu, TARGET_SIGTRAP);
    }
}

'''


def host_compat(source):
    """Rename QEMU's private type tag; newer glibc exposes the same tag.

    No fields, layouts, callers or target ABI are changed. Apply identically to
    matched control and observer, never just one side of the native experiment.
    """
    if source.count('struct sched_attr') != 6 or 'struct vtm_qemu_sched_attr' in source:
        raise ValueError('QEMU 8.2.2 host sched_attr compatibility anchor changed')
    return source.replace('struct sched_attr', 'struct vtm_qemu_sched_attr')


def transform(source):
    if 'VTM_QEMU_GDB_PREEXIT' in source or 'vtm_gdb_preexit' in source:
        raise ValueError('preexit observer already present')
    for anchor, count in ((INCLUDE, 1), (ENTRY, 1), (EXIT, 2)):
        if source.count(anchor) != count:
            raise ValueError(f'QEMU 8.2.2 anchor missing/ambiguous: {anchor!r}')
    # Require the two exact normal process-exit sites, not fatal/signal cleanup.
    for context in (
        '        pthread_mutex_unlock(&clone_lock);\n' + EXIT + '        _exit(arg1);',
        '    case TARGET_NR_exit_group:\n' + EXIT + '        return get_errno(exit_group(arg1));',
    ):
        if source.count(context) != 1:
            raise ValueError('normal process-exit context changed')
    changed = source.replace(INCLUDE, INCLUDE + '#include "gdbstub/user.h"\n')
    changed = changed.replace(ENTRY, HELPER + ENTRY)
    return changed.replace(EXIT, '        vtm_gdb_preexit(cpu);\n' + EXIT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    original = args.source.read_bytes()
    candidate = transform(original.decode()).encode()
    # Output is a new standalone file, never an in-place oracle mutation.
    with args.out.open('xb') as stream:
        stream.write(candidate)
    print(json.dumps(dict(source=str(args.source.resolve()),
        source_sha256=hashlib.sha256(original).hexdigest(),
        output=str(args.out.resolve()), output_sha256=hashlib.sha256(candidate).hexdigest(),
        default_enabled=False, changes_architectural_state=False), indent=2))


if __name__ == '__main__':
    main()
