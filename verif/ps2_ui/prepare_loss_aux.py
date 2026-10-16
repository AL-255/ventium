"""Combine the retained PS/2 loss/resync proposal with current AUX ownership.

Pure text transformation: callers must use a new private output. This does not
modify the production submodule, a frozen FPGA export or any running model.
"""
import hashlib
from pathlib import Path
import re

PARENT = '2ee3b64fc24875b3aaca0e6296a2514161f19cef5e6f79aa90923ca06f1846da'
OLD_PROPOSAL = '29bf4403a43f65684433d2f8221966a460005595d5d21acd4b3a3d83309595e2'
PATCHES = {
    'ps2-loss-fix.patch': '171875417f5161ed26568032373b167520ae10b511d0e0d8f15f6225dcc344f1',
    'ps2-resync-corner.patch': '50d4716800519f6ca385e65973862ad017bab36facf41789ab38f3530de62551',
}
AUX = '        status_mousebufferfull,      // Bit 5: Origin of the selected output byte\n'
OLD_AUX = '        ~(mouse_fifo_empty),         // Bit 5: Mouse output buffer full\n'


def digest(text):
    return hashlib.sha256(text.encode()).hexdigest()


def exact_patch(source, patch):
    """Apply one unified text patch with exact positions/context; no fuzz."""
    lines, changes = source.splitlines(keepends=True), patch.splitlines(keepends=True)
    if not (changes[0].startswith('--- ') and changes[1].startswith('+++ ')):
        raise ValueError('not a single-file unified patch')
    cursor = 0
    output = []
    n = 2
    while n < len(changes):
        match = re.fullmatch(r'@@ -(\d+),(\d+) \+(\d+),(\d+) @@\n', changes[n])
        if match is None:
            raise ValueError('unexpected hunk header')
        start, before_count, new_start, after_count = map(int, match.groups())
        if start-1 < cursor:
            raise ValueError('overlapping hunks')
        output.extend(lines[cursor:start-1]); cursor = start-1
        if len(output) != new_start-1:
            raise ValueError('new hunk position mismatch')
        before = []; after = []; n += 1
        while n < len(changes) and not changes[n].startswith('@@ '):
            row = changes[n]; n += 1
            if row[:1] not in (' ', '-', '+'):
                raise ValueError('unexpected hunk line')
            if row[0] in ' -': before.append(row[1:])
            if row[0] in ' +': after.append(row[1:])
        if len(before) != before_count or len(after) != after_count:
            raise ValueError('hunk length mismatch')
        if lines[cursor:cursor+before_count] != before:
            raise ValueError('source context mismatch')
        output.extend(after); cursor += before_count
    output.extend(lines[cursor:])
    return ''.join(output)


def transform(source):
    if digest(source) != PARENT:
        raise ValueError('current AUX parent drift or already applied')
    result = source
    for name, expected in PATCHES.items():
        patch = (Path(__file__).parent/'proposals'/name).read_text()
        if digest(patch) != expected:
            raise ValueError('retained proposal drift: '+name)
        result = exact_patch(result, patch)
    if result.count(AUX) != 1 or OLD_AUX in result:
        raise ValueError('lost latched AUX ownership')
    # The combination must differ from the previous isolated proposal in this
    # one already-tested AUX expression only. No unreviewed merge resolution.
    if digest(result.replace(AUX, OLD_AUX)) != OLD_PROPOSAL:
        raise ValueError('unexpected combined proposal delta')
    return result
