"""Read-only runtime acceptance guards for the existing FPGA debug interface.

A retirement-ring witness is local execution evidence, not total U+V IPC or
proof that every instruction paired. Architectural serialization stays legal.
"""
import re


def require_running(exec_control, freeze_info):
    # HALT_REQ, BP_EN, HALTED, STEP. BP_CLR is a pulse, not a pairing mode.
    if exec_control & 0x107 or freeze_info & 0x80000000:
        raise ValueError('UV+fast workload is halted, stepped, breakpoint-enabled, or frozen')


def paired_fast_witness(ring_text, *, cs, u_pc, successor_pcs, pipe_state=28):
    """Find consecutive primary retirements spanning a known U/V test pair.

    Callers supply independently decoded U PC and valid post-V destinations.
    An unpaired run includes the V PC as a separate primary retirement and
    therefore cannot satisfy adjacency. Do not use guessed instruction lengths.
    The ring is newest first. This deliberately ignores its legacy lin= field.
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
