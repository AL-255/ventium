"""Move i8237 shared declarations before their generated child instances.

Exact-source private derivative only; no active FPGA export is modified.
Some Verilog elaborators otherwise create undriven per-generate implicit nets,
shadowing the later module-level reset and byte-selector declarations.
"""
import hashlib

PARENT='39eb78423eca313120491301c248b82f58b8aaa89c39e5cd3a3224349e7a9ce1'
RESET="wire reset = write && address == 4'hD;\n"
SELECT='reg flip_flop;\n'
ANCHOR='generate\n\tgenvar i;\n\tfor( i = 0; i < 4; i = i + 1) begin : chan\n'


def transform(source, *, reset=True, selector=True):
    if hashlib.sha256(source.encode()).hexdigest()!=PARENT:
        raise ValueError('DMA declaration predecessor drift/reapplication')
    declarations=''
    for enabled,line in ((reset,RESET),(selector,SELECT)):
        assert source.count(line)==1
        if enabled:
            source=source.replace(line,'')
            declarations+=line
    assert source.count(ANCHOR)==1
    return source.replace(ANCHOR,
        '// Declare shared controls before use in generate scopes: otherwise\n'
        '// Vivado can infer undriven local wires which shadow these names.\n'
        +declarations+'\n'+ANCHOR)
