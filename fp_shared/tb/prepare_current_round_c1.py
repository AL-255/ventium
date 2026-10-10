"""Strict private-tree backport of the previously tested C1 sideband hunks.

Keep the later payload/forwarding optimizations and numeric SRT-floor repair.
This is source preparation, not a production enable or correctness pass. The
legacy core's new output is explicitly connected but not architecturally used:
only the shared-FPU profile is proposed for behavioral qualification here.
"""
import hashlib
from pathlib import Path
import re

import prepare_srt_round_floor as floor

PATCH_SHA256 = 'ed158882e0d619d0758cd10711b21eaab9a2472507ba7fc03853173ba7ebecaf'
FILES = ('rtl/fpu/fpu_srt_div.sv', 'rtl/fpu/fpu_x87_pkg.sv',
         'fp_shared/ven_fp_alu.sv', 'fp_shared/ven_fp_top.sv')
CORE = 'rtl/core/core.sv'
LEGACY_DECL = '  logic [82:0] eng_u_result;'
LEGACY_RESULT = '    .busy(eng_u_busy), .done(eng_u_done), .result(eng_u_result),'


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('missing/ambiguous C1 backport anchor: '+old[:100])
    return text.replace(old, new)


def hunks(patch):
    """Read this exact reviewed patch; apply by complete unique context, no fuzz."""
    if hashlib.sha256(patch.encode()).hexdigest() != PATCH_SHA256:
        raise ValueError('unreviewed C1 patch')
    rows, name, before, after, expected = [], None, [], [], None

    def finish():
        if expected is not None:
            if (len(before), len(after)) != expected:
                raise ValueError('C1 hunk line-count drift')
            rows.append((name, ''.join(before), ''.join(after)))

    for line in patch.splitlines(True):
        if line.startswith('--- a/'):
            finish(); expected = None
            name = line.removeprefix('--- a/').rstrip('\n')
            if name not in FILES:
                raise ValueError('unexpected C1 patch target')
        elif line.startswith('+++ b/'):
            if line.removeprefix('+++ b/').rstrip('\n') != name:
                raise ValueError('C1 patch renames a file')
        elif line.startswith('@@'):
            finish()
            match = re.fullmatch(r'@@ -\d+,(\d+) \+\d+,(\d+) @@\n', line)
            if not match or name is None:
                raise ValueError('unexpected C1 hunk header')
            expected = tuple(map(int, match.groups()))
            before, after = [], []
        elif expected is not None:
            if line == '\n':
                before.append(line); after.append(line)
            elif line.startswith(' '):
                before.append(line[1:]); after.append(line[1:])
            elif line.startswith('-'):
                before.append(line[1:])
            elif line.startswith('+'):
                after.append(line[1:])
            else:
                raise ValueError('unexpected C1 hunk body')
        else:
            raise ValueError('unexpected content outside a C1 hunk')
    finish()
    if {name for name, _, _ in rows} != set(FILES):
        raise ValueError('incomplete C1 patch')
    return rows


def transform(sources, patch=None):
    if set(sources) != set(FILES) | {CORE}:
        raise ValueError('C1 backport needs exactly four FP files and legacy port owner')
    if any('rounded_up' in sources[name] for name in FILES):
        raise ValueError('C1 sideband already present or partially merged')
    out = dict(sources)
    srt = out[FILES[0]]
    # Revert only the already-known three numeric hunks in memory, then apply
    # the historical combined patch. The final numeric hunks must match again.
    srt = once(srt, floor.NEW, floor.OLD)
    srt = once(srt, '  int                  msb, floor_msb, extra;', floor.DECL)
    srt = once(srt, floor.SCAN+'\n    floor_msb = msb;                              // before the independent PC64 round', floor.SCAN)
    out[FILES[0]] = srt
    if patch is None:
        patch = Path(__file__).with_name('round_c1_integration.patch').read_text()
    for name, before, after in hunks(patch):
        out[name] = once(out[name], before, after)
    if floor.NEW not in out[FILES[0]] or 'floor_msb = msb;' not in out[FILES[0]]:
        raise ValueError('numeric SRT repair was not preserved')
    out[CORE] = once(out[CORE], LEGACY_DECL, LEGACY_DECL+'\n  logic eng_u_rounded_up; // shared-FPU repair; legacy status integration remains separate')
    out[CORE] = once(out[CORE], LEGACY_RESULT, LEGACY_RESULT+'\n    .rounded_up(eng_u_rounded_up),')
    return out
