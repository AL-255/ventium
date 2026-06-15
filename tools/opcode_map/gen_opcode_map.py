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

def esc_html(s):
    """Escape text destined for an HTML element body OR a double-quoted attribute
    value (we use it for both), so signal names, ``*``/backticks, and the stray
    ``<``/``>``/``&``/quotes in the analysis text can't break the embedded markup."""
    return ((s or '')
            .replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            .replace('"', '&quot;').replace("'", '&#39;'))

# Status -> human label shown in the tooltip and legend (mirrors the RST legend).
STATUS_LABEL = {
    'implemented': 'implemented', 'partial': 'partial', 'system-only': 'system-only',
    'gap': 'gap', 'prefix': 'prefix', 'undefined': 'undefined',
}

def html_grid(m, prefix):
    """One interactive 16x16 opcode matrix as a CSS-grid of colour-coded cells.

    ``prefix`` is '' for the primary map and '0F ' for the secondary map; it is
    folded into each cell's displayed opcode (the tooltip title). Every cell
    carries its full mnemonic/status/detail/evidence as ``data-*`` attributes —
    the shared tooltip script (emitted once by ``render``) reads them on
    hover/focus/click. Cells are also keyboard-focusable (``tabindex=0``)."""
    out = ['<div class="opc-scroll"><div class="opc-grid" role="grid" aria-label="opcode matrix">']
    out.append('<div class="opc-corner" role="columnheader"></div>')
    for lo in range(16):
        out.append(f'<div class="opc-h opc-colh" role="columnheader">x{lo:X}</div>')
    for hi in range(16):
        out.append(f'<div class="opc-h opc-rowh" role="rowheader">{hi:X}x</div>')
        for lo in range(16):
            i = hi * 16 + lo
            rec = m[f'{i:02X}']
            op = f'{prefix}{i:02X}'
            mnem = rec['mnem']
            cell = (f'<div class="opc-cell opc-{rec["status"]}" role="gridcell" '
                    f'tabindex="0" '
                    f'data-op="{esc_html(op)}" '
                    f'data-mnem="{esc_html(mnem)}" '
                    f'data-status="{esc_html(STATUS_LABEL[rec["status"]])}" '
                    f'data-detail="{esc_html(rec.get("detail", ""))}" '
                    f'data-evidence="{esc_html(rec.get("evidence", ""))}">'
                    f'<span class="opc-op">{i:02X}</span>'
                    f'<span class="opc-mnem">{esc_html(mnem)}</span>'
                    f'</div>')
            out.append(cell)
    out.append('</div></div>')
    return '\n'.join('   ' + ln for ln in out)   # 3-space indent for the raw:: html block

# Inline CSS + JS for the interactive matrix. Self-contained (no external assets,
# no Sphinx extension) so the dependency-free alabaster build keeps working and
# the page degrades to a readable colour grid even with JavaScript off.
OPC_STYLE = r"""
.. raw:: html

   <style>
   .opc-legend{display:flex;flex-wrap:wrap;gap:.4em .9em;margin:.6em 0 1.2em;font-size:.85em}
   .opc-legend .lg{display:inline-flex;align-items:center;gap:.4em}
   .opc-legend .sw{width:1.05em;height:1.05em;border-radius:3px;border:1px solid rgba(0,0,0,.25);display:inline-block}
   .opc-scroll{overflow-x:auto;margin:.4em 0 1.4em;padding-bottom:.4em}
   .opc-grid{display:grid;grid-template-columns:2.4em repeat(16,minmax(4.6em,1fr));gap:2px;min-width:60em;font-family:var(--mono,SFMono-Regular,Menlo,Consolas,monospace)}
   .opc-h{display:flex;align-items:center;justify-content:center;font-weight:700;font-size:.8em;color:#444;background:#f0f0f0;border-radius:3px;padding:.2em 0}
   .opc-corner{background:transparent}
   .opc-cell{position:relative;cursor:default;border-radius:3px;padding:.22em .3em;min-height:2.7em;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-start;border:1px solid rgba(0,0,0,.12);transition:transform .05s ease,box-shadow .05s ease;outline:none}
   .opc-cell:hover,.opc-cell:focus,.opc-cell.opc-pin{transform:scale(1.04);box-shadow:0 2px 8px rgba(0,0,0,.28);z-index:3}
   .opc-cell .opc-op{font-size:.62em;font-weight:700;opacity:.6;line-height:1}
   .opc-cell .opc-mnem{font-size:.72em;line-height:1.05;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
   .opc-implemented{background:#e6f4ea;border-color:#9ccaa8}
   .opc-partial    {background:#fff5da;border-color:#e6c463}
   .opc-system-only{background:#e4eefb;border-color:#9bbde8}
   .opc-gap        {background:#fde7e7;border-color:#e6a3a3}
   .opc-prefix     {background:#f1e8f8;border-color:#c8a8e0}
   .opc-undefined  {background:#f4f4f4;border-color:#dadada;color:#888}
   .sw-implemented{background:#e6f4ea}.sw-partial{background:#fff5da}.sw-system-only{background:#e4eefb}
   .sw-gap{background:#fde7e7}.sw-prefix{background:#f1e8f8}.sw-undefined{background:#f4f4f4}
   #opc-tip{position:absolute;z-index:50;max-width:30em;background:#1e1e2a;color:#f4f4f6;border-radius:6px;padding:.6em .75em;font-size:.8rem;line-height:1.35;box-shadow:0 6px 24px rgba(0,0,0,.4);pointer-events:none;display:none}
   #opc-tip .t-op{font-family:var(--mono,Menlo,Consolas,monospace);font-weight:700;color:#ffd479}
   #opc-tip .t-badge{display:inline-block;margin-left:.5em;padding:.05em .5em;border-radius:10px;font-size:.78em;font-weight:700;color:#1e1e2a}
   #opc-tip .t-detail{margin:.45em 0 0}
   #opc-tip .t-ev{margin:.45em 0 0;font-family:var(--mono,Menlo,Consolas,monospace);font-size:.84em;opacity:.72;white-space:pre-wrap}
   #opc-tip .b-implemented{background:#7fd49a}#opc-tip .b-partial{background:#f0cf6a}
   #opc-tip .b-system-only{background:#8fb6ec}#opc-tip .b-gap{background:#ef9a9a}
   #opc-tip .b-prefix{background:#cdaee6}#opc-tip .b-undefined{background:#cfcfcf}
   .opc-hint{font-size:.82em;color:#666;margin:.2em 0 .8em}
   </style>
   <div id="opc-tip" role="tooltip"></div>
"""

OPC_SCRIPT = r"""
.. raw:: html

   <script>
   (function(){
     var tip=document.getElementById('opc-tip'); if(!tip) return;
     var pinned=null;
     function fill(c){
       var st=c.getAttribute('data-status');
       var h='<span class="t-op">'+c.getAttribute('data-op')+'</span>'
            +'<span class="t-badge b-'+st+'">'+st+'</span>'
            +'<div class="t-mnem"><strong>'+c.getAttribute('data-mnem')+'</strong></div>';
       var d=c.getAttribute('data-detail'); if(d) h+='<div class="t-detail">'+d+'</div>';
       var e=c.getAttribute('data-evidence'); if(e) h+='<div class="t-ev">'+e+'</div>';
       tip.innerHTML=h;
     }
     function place(c){
       tip.style.display='block';
       var r=c.getBoundingClientRect(), tr=tip.getBoundingClientRect();
       var sx=window.pageXOffset, sy=window.pageYOffset;
       var x=r.left+sx, y=r.bottom+sy+6;
       var maxx=sx+document.documentElement.clientWidth-tr.width-8;
       if(x>maxx) x=Math.max(sx+8,maxx);
       if(y+tr.height>sy+document.documentElement.clientHeight && r.top+sy-tr.height-6>sy)
         y=r.top+sy-tr.height-6;            // flip above if it would overflow the bottom
       tip.style.left=x+'px'; tip.style.top=y+'px';
     }
     function show(c){ if(pinned&&pinned!==c) return; fill(c); place(c); }
     function hide(){ if(pinned) return; tip.style.display='none'; }
     document.querySelectorAll('.opc-cell').forEach(function(c){
       c.addEventListener('mouseenter',function(){show(c);});
       c.addEventListener('mouseleave',hide);
       c.addEventListener('focus',function(){show(c);});
       c.addEventListener('blur',hide);
       c.addEventListener('click',function(ev){
         ev.stopPropagation();
         if(pinned===c){pinned=null;c.classList.remove('opc-pin');tip.style.display='none';return;}
         if(pinned) pinned.classList.remove('opc-pin');
         pinned=c; c.classList.add('opc-pin'); fill(c); place(c);
       });
     });
     document.addEventListener('click',function(){
       if(pinned){pinned.classList.remove('opc-pin');pinned=null;tip.style.display='none';}
     });
   })();
   </script>
"""

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
    MEANING = {
        'implemented': 'Fully decoded and retired; behaviour QEMU-matched for the P54C model.',
        'partial': 'Decoded, but some ModRM/x87 sub-forms, modes, or value-ranges are gated off and HALT.',
        'system-only': 'Decodes only in ``sys_mode``; user mode HALTs.',
        'gap': 'Architecturally-valid P54C opcode with no decode arm -> HALTs. (Implementation target.)',
        'prefix': 'Legacy/segment/operand prefix; consumed in the prefix loop.',
        'undefined': 'Not a P54C instruction (MMX/SSE/post-Pentium/reserved); HALTs.',
    }
    L.append('Status legend')
    L.append('-------------')
    L.append('')
    # Inline CSS + the shared tooltip element, then a colour-coded legend. The
    # grids below are interactive: hover (or focus, or click-to-pin) any cell for
    # the full mnemonic, status, decode detail, and RTL evidence.
    L.append(OPC_STYLE.strip('\n'))
    L.append('')
    L.append('.. raw:: html')
    L.append('')
    L.append('   <div class="opc-legend">')
    for st in ORDER:
        L.append(f'   <span class="lg"><span class="sw sw-{st}"></span>'
                 f'<strong>{st}</strong> — {esc_html(MEANING[st])}</span>')
    L.append('   </div>')
    L.append('   <p class="opc-hint">Hover (or tab to, or click to pin) any cell for the full '
             'mnemonic, decode status, sub-form notes, and the RTL evidence. The same legend '
             'glyphs (``I ~ S X P .``) appear in the appendix and coverage table below.</p>')
    L.append('')
    for name, m, c, pfx in (('Primary one-byte opcode map', P, cp, ''),
                            ('Secondary ``0F`` opcode map', S, cs, '0F ')):
        L.append(name)
        L.append('-' * len(name))
        L.append('')
        L.append('High nibble runs down the left, low nibble across the top. Cells are')
        L.append('colour-coded by status; hover/focus/click for full details.')
        L.append('')
        L.append('.. raw:: html')
        L.append('')
        L.append(html_grid(m, pfx))
        L.append('')
    # The tooltip behaviour script runs once, after both grids exist in the DOM.
    L.append(OPC_SCRIPT.strip('\n'))
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
