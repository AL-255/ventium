"""Read-only runtime acceptance guards for the existing FPGA debug interface.

A retirement-ring witness is local execution evidence, not total U+V IPC or
proof that every instruction paired. Architectural serialization stays legal.
"""
import re


def require_running(exec_control, freeze_info, *, capability):
    """Check ABI-5 *readback*, not a command word or execution history.

    STEP and BP_CLR are write-only pulses. A zero readback cannot establish
    that no STEP occurred earlier; preserve the complete controller command
    record and obtain an independent paired fast-path witness. Do not interpret
    an unknown observer ABI using the source image's register layout.
    """
    if capability != 0x56450005:
        raise ValueError('unsupported execution-debug ABI for the running guard')
    if (type(exec_control) is not int or not 0 <= exec_control <= 0xffffffff or
            type(freeze_info) is not int or not 0 <= freeze_info <= 0xffffffff):
        raise ValueError('execution/freeze readback must be unsigned 32-bit words')
    if exec_control & ~0x7:
        raise ValueError('reserved ABI-5 readback bits: do not pass a command word')
    # Only HALT_REQ, BP_EN and HALTED are readable on this ABI.
    if exec_control & 0x7 or freeze_info & 0x80000000:
        raise ValueError('workload is halted, breakpoint-enabled, or frozen')
    return dict(running_observed=True, step_history_observable=False,
                uv_fast_qualified=False)


def paired_fast_witness(ring_text, *, cs, u_pc, successor_pcs, pipe_state):
    """Find consecutive primary retirements spanning a known U/V test pair.

    Callers supply independently decoded U PC and valid post-V destinations.
    An unpaired run includes the V PC as a separate primary retirement and
    therefore cannot satisfy adjacency. Do not use guessed instruction lengths.
    The caller must establish a coherent ring capture and derive pipe_state
    from this build's enum: optional states change its numeric value. The ring
    is newest first. This deliberately ignores its legacy lin= field.
    """
    pattern = re.compile(r'^\[\s*(\d+)\] cs=([0-9a-fA-F]{4}) eip=([0-9a-fA-F]{8}) state=(\d+)\b')
    rows = []
    for line in ring_text.splitlines():
        match = pattern.match(line)
        if match:
            index, selector, pc, state = match.groups()
            rows.append((int(index), int(selector, 16), int(pc, 16), int(state)))
        elif line.startswith('['):
            raise ValueError('malformed retirement-ring row')
    if [row[0] for row in rows] != list(range(len(rows))):
        raise ValueError('retirement-ring ordering is incomplete')
    for newer, older in zip(rows, rows[1:]):
        if (older[1:] == (cs, u_pc, pipe_state) and newer[1] == cs and
                newer[2] in successor_pcs and newer[3] == pipe_state):
            return dict(primary_pc=f'{u_pc:08x}', successor_pc=f'{newer[2]:08x}',
                        primary_ring_index=older[0], successor_ring_index=newer[0],
                        cs=f'{cs:04x}', state=pipe_state,
                        evidence='adjacent primary retirements span independently decoded V',
                        total_gameplay_ipc=None)
    raise ValueError('no executed UV+fast test-pair witness; mode is not qualified')
