"""Private compact FST-memory C1 repair; retain old converter value/flag ABI.

Expose the existing increment decision, rather than comparing/reconverting
the result or adding another adder. No pipeline stage or occupancy changes.
"""
from pathlib import Path
import re


def once(text,before,after):
    if text.count(before)!=1: raise ValueError('missing/ambiguous FST memory anchor: '+before)
    return text.replace(before,after)


def transform_package(text):
    for bits,width in ((32,35),(64,67)):
        old=f'fx_to_f{bits}_ex'; new=f'fx_to_f{bits}_c1'
        pattern=rf'  function automatic logic \[{width-1}:0\] {old}\(.*?  endfunction'
        matches=list(re.finditer(pattern,text,re.S))
        if len(matches)!=1 or f'function automatic logic [{width}:0] {new}(' in text:
            raise ValueError('converter missing, duplicated or already patched')
        match=matches[0];body=match.group()
        body=once(body,f'logic [{width-1}:0] {old}(',f'logic [{width}:0] {new}(')
        body=body.replace(old+' =',new+' =')
        body=once(body,'    logic        s, oe, ue, pe;','    logic        s, oe, ue, pe, rounded_up;')
        body=once(body,"      oe=1'b0; ue=1'b0; pe=1'b0;","      oe=1'b0; ue=1'b0; pe=1'b0; rounded_up=1'b0;")
        # All original return payload bits remain in their original order.
        body,count=re.subn(r'('+new+r' = |return )\{',r'\1{rounded_up, ',body)
        if count!=10: raise ValueError('unexpected converter return count')
        up=("fx_dir_up({24'd0, rem}, 64'h8000000000, frac[0], s, rc)" if bits==32 else
            "fx_dir_up({53'd0, rem}, 64'h400, frac[0], s, rc)")
        if body.count('if ('+up+')')!=2: raise ValueError('missing rounding owners')
        body=body.replace('          if ('+up+')','          rounded_up = '+up+';\n          if (rounded_up)')
        overflow="oe=1'b1; pe=1'b1;"
        if body.count(overflow)!=2: raise ValueError('missing overflow owners')
        body=body.replace(overflow,overflow+"\n          rounded_up = !((rc==2'd3) || (!s && rc==2'd1) || (s && rc==2'd2));")
        wrapper=(f'\n  // Compatibility wrapper: original value/exception payload unchanged.\n'
            f'  function automatic logic [{width-1}:0] {old}(input logic [79:0] v, input logic [1:0] rc);\n'
            f'    logic [{width}:0] result_with_c1;\n'
            f'    begin result_with_c1 = {new}(v, rc); return result_with_c1[{width-1}:0]; end\n'
            f'  endfunction')
        text=text[:match.start()]+body+wrapper+text[match.end():]
    return text


def transform_misc(text):
    text=once(text,'    output      logic        flag_pe\n',
        '    output      logic        flag_pe,\n    output      logic        rounded_up\n')
    text=once(text,"      flag_pe    <= 1'b0;","      flag_pe    <= 1'b0;\n      rounded_up <= 1'b0;")
    text=once(text,"          flag_pe <= 1'b0;","          flag_pe <= 1'b0;\n          rounded_up <= 1'b0;")
    for bits,width in ((32,35),(64,67)):
        text=once(text,f'logic [{width-1}:0] f{bits};',f'logic [{width}:0] f{bits};')
        text=once(text,f"f{bits} = {width}'d0;",f"f{bits} = {width+1}'d0;")
        text=once(text,f'fx_to_f{bits}_ex(a_q, rc_q);',f'fx_to_f{bits}_c1(a_q, rc_q);\n              rounded_up <= f{bits}[{width}];')
    return text


def transform_top(text):
    text=once(text,'  logic        misc_ie, misc_oe, misc_ue, misc_pe;',
        '  logic        misc_ie, misc_oe, misc_ue, misc_pe, misc_rounded_up;')
    text=once(text,'      .flag_pe(misc_pe)\n','      .flag_pe(misc_pe),\n      .rounded_up(misc_rounded_up)\n')
    marker='    if ((top_state == TOP_MISC) && misc_done) begin'
    end='    if ((top_state == TOP_BCD_LOAD) && bcd_load_done) begin'
    if text.count(marker)!=1 or text.count(end)!=1:
        raise ValueError('missing/ambiguous misc owner boundary')
    start_at=text.index(marker); end_at=text.index(end,start_at)
    body=text[start_at:end_at]
    body=once(body,'      if (misc_ie || misc_oe || misc_ue || misc_pe) begin',
        '      if (misc_ie || misc_oe || misc_ue || misc_pe ||\n'
        '          (pending_op inside {FX_FST_M32, FX_FST_M64, FX_FST_M80})) begin')
    body=once(body,"                        (misc_pe ? 16'h0020 : 16'h0000);",
        "                        (misc_pe ? 16'h0020 : 16'h0000);\n"
        '        // Only the completing FST owner consumes the registered bit.\n'
        '        // Exact m80 stores clear C1; other misc opcode semantics are separate.\n'
        '        if (pending_op inside {FX_FST_M32, FX_FST_M64, FX_FST_M80})\n'
        '          c_status_data[9] = misc_rounded_up;')
    return text[:start_at]+body+text[end_at:]


TRANSFORMS={'rtl/fpu/fpu_x87_pkg.sv':transform_package,
            'fp_shared/ven_fp_misc.sv':transform_misc,
            'fp_shared/ven_fp_top.sv':transform_top}


def prepare(root):
    root=Path(root)
    outputs={root/name:fn((root/name).read_text()) for name,fn in TRANSFORMS.items()}
    for path,text in outputs.items(): path.write_text(text)
