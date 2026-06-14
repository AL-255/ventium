#!/usr/bin/env python3
# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Generate the Ventium x86 opcode-map reference (two 16x16 grids) for the docs,
and verify the coverage data still matches the RTL decoder.

This is the FIXED (deterministic, CI-runnable) decoder-coverage workflow: it keeps
docs/sphinx/isa/opcode-map.rst in lock-step with rtl/core/core.sv so the diagram
can never silently go stale. It is wired into .github/workflows/docs.yml to run on
every Sphinx build.

  tools/opcode_map/gen_opcode_map.py            # regenerate the .rst from the data
  tools/opcode_map/gen_opcode_map.py --check    # CI: fail if the committed .rst is stale
  tools/opcode_map/gen_opcode_map.py --verify-rtl  # CI: fail if the data drifted from core.sv

SOURCE OF TRUTH: tools/opcode_map/coverage_data.json — per-opcode {mnem,status,
detail,evidence}, status in {implemented,partial,system-only,gap,prefix,undefined}.
When you add/remove a decode arm in core.sv, update that JSON and re-run this tool;
--verify-rtl is the guard that reminds you (it cross-checks the FX_* enum and the
one-byte `8'hXX:` functional-decode arms against the data).
"""
import json, os, sys, re, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..'))
DATA = os.path.join(HERE, 'coverage_data.json')
CORE = os.path.join(REPO, 'rtl', 'core', 'core.sv')
PKG  = os.path.join(REPO, 'rtl', 'core', 'ventium_decode_pkg.sv')
RST  = os.path.join(REPO, 'docs', 'sphinx', 'isa', 'opcode-map.rst')

GLYPH = {'implemented': 'I', 'partial': '~', 'system-only': 'S',
         'gap': 'X', 'prefix': 'P', 'undefined': '.'}
ORDER = ['implemented', 'partial', 'system-only', 'gap', 'prefix', 'undefined']

def load():
    d = json.load(open(DATA))
    # fill any missing cell (0x0F primary = the two-byte escape; others undefined)
    for mapname in ('primary', 'secondary'):
        m = d[mapname]
        for i in range(256):
            k = f'{i:02X}'
            if k not in m:
                if mapname == 'primary' and i == 0x0F:
                    m[k] = {'mnem': '0F (two-byte escape)', 'status': 'prefix', 'detail': '', 'evidence': ''}
                else:
                    m[k] = {'mnem': '(reserved)', 'status': 'undefined', 'detail': '', 'evidence': ''}
    return d

def esc(s):
    """Escape RST inline-markup metacharacters in free text (signal names full of
    underscores, stray ``*``/backticks/pipes from the analysis) so the generated
    appendix never trips docutils (-W in CI)."""
    s = (s or '').replace('\\', '')
    s = s.replace('*', r'\*').replace('`', r'\`').replace('|', r'\|')
    s = re.sub(r'_(?=[^A-Za-z0-9_]|$)', r'\_', s)   # kill trailing-underscore "references" (RST links)
    return s

def short(mnem, w=9):
    s = re.sub(r'\s+', '', mnem)            # squeeze spaces so the grid aligns
    return (s[:w]).ljust(w)

def grid(m):
    """16x16 ASCII grid; high nibble down the left, low nibble across the top."""
    out = []
    hdr = '       ' + ' '.join(f'x{c:X}'.ljust(11) for c in range(16))
    out.append(hdr.rstrip())
    for hi in range(16):
        cells = []
        for lo in range(16):
            rec = m[f'{hi*16+lo:02X}']
            cells.append(f'{short(rec["mnem"])} {GLYPH[rec["status"]]}')
        out.append(f'  {hi:X}x  ' + ' '.join(cells).rstrip())
    return '\n'.join(out)

def counts(m):
    c = {k: 0 for k in ORDER}
    for i in range(256):
        c[m[f'{i:02X}']['status']] += 1
    return c

def appendix(m, mapname):
    lines = []
    for i in range(256):
        rec = m[f'{i:02X}']
        if rec['status'] in ('partial', 'gap', 'system-only'):
            pfx = '0F ' if mapname == 'secondary' else ''
            det = esc(rec.get('detail', ''))
            ev = esc(rec.get('evidence', ''))
            lines.append(f"* ``{pfx}{i:02X}`` **{esc(rec['mnem'])}** — *{rec['status']}*. {det} {('[' + ev + ']') if ev else ''}".rstrip())
    return lines

def render(d):
    P, S = d['primary'], d['secondary']
    cp, cs = counts(P), counts(S)
    L = []
    L.append('.. _opcode-map:')
    L.append('')
    L.append('Ventium x86 Opcode-Map Reference (auto-generated)')
    L.append('=================================================')
    L.append('')
    L.append('.. note::')
    L.append('   This page is **generated** by ``tools/opcode_map/gen_opcode_map.py`` from')
    L.append('   ``tools/opcode_map/coverage_data.json`` and verified against')
    L.append('   ``rtl/core/core.sv`` on every Sphinx build (``.github/workflows/docs.yml``).')
    L.append('   Do not edit by hand — update the JSON and re-run the generator.')
    L.append('')
    L.append('Complete one-byte (primary) and two-byte (``0F``-prefixed) x86 opcode maps as')
    L.append('decoded by the Ventium P54C core in **functional mode** (the KV260 board path,')
    L.append('``cycle_mode=0``). Reference model: ``qemu -cpu pentium`` (P54C: no MMX/SSE).')
    L.append('Out-of-scope opcodes HALT loudly (``d_unknown`` -> ``S_HALT``); they are never')
    L.append('silently mis-executed.')
    L.append('')
    L.append('Status legend')
    L.append('-------------')
    L.append('')
    L.append('.. list-table::')
    L.append('   :header-rows: 1')
    L.append('   :widths: 8 18 74')
    L.append('')
    L.append('   * - Glyph')
    L.append('     - Status')
    L.append('     - Meaning')
    for st, gl in ((s, GLYPH[s]) for s in ORDER):
        meaning = {
            'implemented': 'Fully decoded and retired; behaviour QEMU-matched for the P54C model.',
            'partial': 'Decoded, but some ModRM/x87 sub-forms, modes, or value-ranges are gated off and HALT.',
            'system-only': 'Decodes only in ``sys_mode``; user mode HALTs.',
            'gap': 'Architecturally-valid P54C opcode with no decode arm -> HALTs. (Implementation target.)',
            'prefix': 'Legacy/segment/operand prefix; consumed in the prefix loop.',
            'undefined': 'Not a P54C instruction (MMX/SSE/post-Pentium/reserved); HALTs.',
        }[st]
        L.append(f'   * - ``{gl}``')
        L.append(f'     - {st}')
        L.append(f'     - {meaning}')
    L.append('')
    for name, m, c in (('Primary one-byte opcode map', P, cp), ('Secondary ``0F`` opcode map', S, cs)):
        L.append(name)
        L.append('-' * len(name))
        L.append('')
        L.append('High nibble runs down the left, low nibble across the top. Each cell is a')
        L.append('terse mnemonic followed by its status glyph.')
        L.append('')
        L.append('.. code-block:: text')
        L.append('')
        for ln in grid(m).split('\n'):
            L.append('   ' + ln)
        L.append('')
    L.append('Coverage summary')
    L.append('----------------')
    L.append('')
    L.append('.. list-table::')
    L.append('   :header-rows: 1')
    L.append('   :widths: 40 30 30')
    L.append('')
    L.append('   * - Status')
    L.append('     - Primary (256)')
    L.append('     - ``0F`` (256)')
    for st in ORDER:
        L.append(f'   * - ``{GLYPH[st]}`` {st}')
        L.append(f'     - {cp[st]}')
        L.append(f'     - {cs[st]}')
    L.append('')
    L.append('Detail: partial / gap / system-only cells')
    L.append('-----------------------------------------')
    L.append('')
    L.append('Primary map')
    L.append('~~~~~~~~~~~')
    L.append('')
    L.extend(appendix(P, 'primary') or ['* (none)'])
    L.append('')
    L.append('Secondary ``0F`` map')
    L.append('~~~~~~~~~~~~~~~~~~~~~')
    L.append('')
    L.extend(appendix(S, 'secondary') or ['* (none)'])
    L.append('')
    return '\n'.join(L) + '\n'

def decode_fingerprint():
    """A comment/whitespace-insensitive fingerprint of the decoder's STRUCTURE.

    The multiset of decode-defining tokens across core.sv + the FX_/K_ enums:
    every opcode/sub-opcode case label, every micro-op assignment, and every
    d_unknown HALT. Adding/removing/retargeting ANY decode arm (primary, 0F,
    x87, or group sub-form) changes this hash; comments and reflow do not. This
    is the staleness tripwire: if the decoder changes, the hash moves, and CI
    insists the opcode-map data be re-reviewed + the fingerprint refreshed.
    """
    import hashlib
    core = open(CORE).read()
    pkg = open(PKG).read()
    toks = []
    toks += re.findall(r"8'[hb][0-9a-fA-F_?]+\s*[:,]", core)        # case labels
    toks += re.findall(r"d_fxop\s*=\s*FX_[A-Z0-9_]+", core)         # x87 micro-ops
    toks += re.findall(r"d_kind\s*=\s*K_[A-Z0-9_]+", core)          # integer kinds
    toks += re.findall(r"d_sysop\s*=\s*SYS_[A-Z0-9_]+", core)       # system ops
    toks += re.findall(r"d_(?:unknown|halt|is_nop|int80|f00f)\s*=\s*1'b1", core)
    toks += re.findall(r"\bFX_[A-Z0-9_]+\b", pkg)                   # the enum itself
    norm = sorted(re.sub(r'\s+', '', t) for t in toks)
    return hashlib.sha256('\n'.join(norm).encode()).hexdigest()

def verify_rtl(d):
    """Cross-check the data against core.sv so the map cannot silently drift.

    Robust, low-false-positive (no full SV parse):
      1. Every FX_* x87 micro-op cited in the data's evidence exists in the
         ventium_decode_pkg.sv fxop_e enum (catches renamed/removed ops).
      2. The decoder STRUCTURE fingerprint matches the one recorded in the data
         (catches any added/removed/retargeted decode arm -> re-review needed).
    Returns a list of human-readable drift complaints (empty == in sync).
    """
    pkg = open(PKG).read()
    problems = []
    enum = set(re.findall(r'\bFX_[A-Z0-9_]+\b', pkg))
    for mapname in ('primary', 'secondary'):
        for k, rec in d[mapname].items():
            for fx in re.findall(r'\bFX_[A-Z0-9_]+\b', rec.get('evidence', '') + ' ' + rec.get('detail', '')):
                if fx not in enum:
                    problems.append(f'{mapname} {k}: evidence cites {fx} which is not in fxop_e')
    recorded = d.get('_decode_fingerprint')
    actual = decode_fingerprint()
    if recorded != actual:
        problems.append('core.sv decoder STRUCTURE changed since the opcode map was last '
                        f'regenerated (fingerprint {recorded} -> {actual}). Review the new/'
                        'changed decode arms, update tools/opcode_map/coverage_data.json, then '
                        'run: gen_opcode_map.py --update-fingerprint && gen_opcode_map.py')
    return problems

def main():
    d = load()
    if '--update-fingerprint' in sys.argv:
        raw = json.load(open(DATA))
        raw['_decode_fingerprint'] = decode_fingerprint()
        json.dump(raw, open(DATA, 'w'), indent=1)
        sys.stderr.write('updated _decode_fingerprint = %s\n' % raw['_decode_fingerprint'])
        return 0
    rst = render(d)
    if '--verify-rtl' in sys.argv:
        probs = verify_rtl(d)
        if probs:
            sys.stderr.write('opcode-map DRIFT vs core.sv:\n' + '\n'.join('  - ' + p for p in probs) + '\n')
            return 1
        sys.stderr.write('opcode-map: data in sync with core.sv (FX-enum + decode fingerprint OK)\n')
        return 0
    if '--check' in sys.argv:
        cur = open(RST).read() if os.path.exists(RST) else ''
        if cur != rst:
            sys.stderr.write('opcode-map STALE: %s differs from generated output.\n'
                             'Run: python3 tools/opcode_map/gen_opcode_map.py && git add %s\n' % (RST, RST))
            return 1
        sys.stderr.write('opcode-map: %s up to date\n' % RST)
        return 0
    os.makedirs(os.path.dirname(RST), exist_ok=True)
    open(RST, 'w').write(rst)
    sys.stderr.write('wrote %s (%d primary + %d secondary cells)\n'
                     % (RST, len(d['primary']), len(d['secondary'])))
    return 0

if __name__ == '__main__':
    sys.exit(main())
