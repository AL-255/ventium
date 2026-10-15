"""Separate buffered fetch metadata from the live semantic decoder's input mux.

Private exact-parent experiment. Reuse decode_stages itself, with semantic
outputs open on the buffered instance, rather than duplicating an opcode table.
There is no extra cycle or modified decoder/permission/fragment equation.
"""
import hashlib
import re

FILE = 'rtl/core/core.sv'
PARENT = '238cd9f713cc6e84a6881cb5e06b8ff341a90cb428be8882b1f1b2d974491ac4'
DECODER = 'e961f42125090b880ec06cddd1c9d2414af2f0a458e3fb008d39325b2b085292'
FIELDS = ('d_fetch_need', 'd_fetch_len', 'd_fetch_fault_len',
          'd_fetch_meta_ready', 'd_fetch_overlong', 'd_fetch_modrm',
          'd_fetch_header_ready', 'd_fetch_header_x87', 'd_fetch_header_cpl0')


def instance(source):
    begin = source.index('  decode_stages u_decode_stages (\n')
    end = source.index('\n  );', begin) + len('\n  );')
    return source[begin:end]


def transform(source):
    if hashlib.sha256(source.encode()).hexdigest() != PARENT:
        raise ValueError('fetch metadata parent drift/reapplication')
    old = instance(source)
    primary = old
    for name in FIELDS:
        pattern = r'^(    \.' + name + r'\s*)\(' + name + r'\),$'
        found = re.findall(pattern, primary, re.M)
        if len(found) != 1:
            raise ValueError('metadata connection drift: ' + name)
        original = found[0] + '(' + name + '),'
        primary = primary.replace(original, '`ifdef VEN_PIPE_SDISPATCH\n' +
            found[0] + '(live_' + name + '),\n`else\n' + original + '\n`endif')
    secondary = old.replace('u_decode_stages', 'u_fetch_metadata')
    mux = '''`ifdef VEN_PIPE_SDISPATCH
    .ibuf          (refdecode_ibuf),
`else
    .ibuf          (ibuf),
`endif'''
    if secondary.count(mux) != 1:
        raise ValueError('decoder input mux drift')
    secondary = secondary.replace(mux, '    .ibuf          (ibuf),')
    # The interface order is pinned. All input connections are preserved;
    # every semantic output is explicitly open, avoiding PINMISSING waivers.
    marker = '    // leaked prefix/ModR/M intermediates the spine/FSM also reads\n'
    inputs, outputs = secondary.split(marker)
    outputs = re.sub(r'(\.\w+\s*)\((\w+)\)',
        lambda m: m[0] if m[2] in FIELDS else m[1] + '()', outputs)
    secondary = inputs + marker + outputs
    declarations = '\n'.join('  logic ' + ('[4:0] ' if n in FIELDS[:3] else '') +
                              'live_' + n + ';' for n in FIELDS)
    witness = '\n'.join('    assert (' + n + ' === live_' + n + ')\n' +
        '      else $fatal(1, "FETCH-METADATA-OWNER: ' + n + '");' for n in FIELDS)
    new = '''`ifdef VEN_PIPE_SDISPATCH
  // Fetch demand and S_DECODE fault metadata consume the buffered instruction,
  // never S_PIPE/S_EXEC's live window. Keep that ownership structural: routing
  // the live byte mux through semantic length decode and back into the memory
  // response cone creates a long, state-incompatible combinational path.
  // This second instance retains only metadata in synthesis. It uses the SAME
  // decoder implementation, not another independently maintained opcode table.
''' + declarations + '\n`endif\n' + primary + '\n\n`ifdef VEN_PIPE_SDISPATCH\n' + secondary + '''
`ifndef SYNTHESIS
  // Every consumer of these fields is FETCH/DECODE-qualified. Other states'
  // semantic descriptors still come from the unchanged live instance.
  always_ff @(posedge clk) if (rst_n && ((state == S_FETCH) || (state == S_DECODE))) begin
''' + witness + '\n  end\n`endif\n`endif'
    return source.replace(old, new)


def region(source):
    begin = source.index('`ifdef VEN_PIPE_SDISPATCH\n  // The reference decoder')
    end = source.index('\n\n\n  // M7.1: syscall_active', begin)
    return source[begin:end]
