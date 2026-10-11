#!/usr/bin/env python3
"""Create a reviewed mouse-CSR overlay, never edit an active FPGA export.

This is source preparation only, not a bitstream/build/suite qualification.
The current timing candidate's three wrapper files are pinned explicitly.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil

BASE = {
    'src/ven_mgmt_axil.v': '9fe3674227d3c5a4da3646125e476a51c2c6bc68932b6dba7046119e9e42aaad',
    'src/rk_ao486_system_pl.v': 'fe50b53ece11b88855d54a8d0e3bf3626986a7d2485c34138547f5b6163b336c',
    'hw/create_project.tcl': '8f763c521956bf55fbb01e614d86365e81433ddbf7d2c45c2a4d7a1f33ed5dd6',
}


def replace_one(text, old, new):
    if text.count(old) != 1:
        raise ValueError('missing/ambiguous/already-applied integration anchor: ' + old[:70])
    return text.replace(old, new)


def management(text):
    if 'mouse_csr_' in text:
        raise ValueError('mouse CSR integration already present')
    text = replace_one(text, '//   0x390 keyboard transport status  0x3A0 keyboard transport capability\n',
                       '//   0x390 keyboard transport status  0x3A0 keyboard transport capability\n'
                       '//   0x400..0x4A0 hosted mouse mailboxes (ven_ps2_mailbox ABI 1)\n')
    text = replace_one(text, '    output reg          core_reset_n,', '''    // One-cycle registered writes; all four byte strobes reach the mailbox.
    // The current read address selects combinational mailbox data, which the
    // ordinary AXI read FSM captures and retains under R-channel backpressure.
    output reg          mouse_csr_write,
    output reg [3:0]    mouse_csr_waddr,
    output reg [31:0]   mouse_csr_wdata,
    output reg [3:0]    mouse_csr_wstrb,
    output wire [3:0]   mouse_csr_raddr,
    input wire [31:0]   mouse_csr_rdata,
    output reg          core_reset_n,''')
    text = replace_one(text, '    reg [15:0] ctrl;\n',
                       '    reg [15:0] ctrl;\n    assign mouse_csr_raddr = s_araddr[7:4];\n')
    text = replace_one(text, '            kbd_inject_data<=0; kbd_inject_valid<=0;\n',
                       '            kbd_inject_data<=0; kbd_inject_valid<=0;\n'
                       '            mouse_csr_write<=0; mouse_csr_waddr<=0; mouse_csr_wdata<=0; mouse_csr_wstrb<=0;\n')
    text = replace_one(text, '            case (wst)\n', '            mouse_csr_write<=0;\n            case (wst)\n')
    text = replace_one(text, '                    s_awready<=1; s_wready<=1;\n', '''                    s_awready<=1; s_wready<=1;
                    if (s_awaddr[11:8] == 4'h4 && s_awaddr[3:0] == 4'h0) begin
                        mouse_csr_write <= 1;
                        mouse_csr_waddr <= s_awaddr[7:4];
                        mouse_csr_wdata <= s_wdata;
                        mouse_csr_wstrb <= s_wstrb;
                    end
''')
    text = replace_one(text, '                            12\'h3A0: s_rdata<=KBD_INJECT_CAP;\n', '''                            12'h3A0: s_rdata<=KBD_INJECT_CAP;
                            12'h400, 12'h410, 12'h420, 12'h430,
                            12'h440, 12'h450, 12'h460, 12'h470,
                            12'h480, 12'h490, 12'h4A0, 12'h4B0,
                            12'h4C0, 12'h4D0, 12'h4E0, 12'h4F0:
                                s_rdata <= mouse_csr_rdata;
''')
    return text


def wrapper(text):
    if 'mouse_csr_' in text or 'ven_ps2_mailbox' in text:
        raise ValueError('mouse wrapper integration already present')
    text = replace_one(text, '    wire soc_reset;\n', '''    wire soc_reset;
    wire mouse_csr_write;
    wire [3:0] mouse_csr_waddr, mouse_csr_wstrb, mouse_csr_raddr;
    wire [31:0] mouse_csr_wdata, mouse_csr_rdata;
    wire mouse_tx_valid, mouse_tx_ready, mouse_tx_done, mouse_tx_aborted;
    wire mouse_rx_valid, mouse_rx_ready, mouse_rx_aborted;
    wire [7:0] mouse_tx_data, mouse_rx_data;
    wire [1:0] mouse_rx_error;
    wire ps2_mouseclk_host, ps2_mousedat_host, ps2_mouseclk_dev, ps2_mousedat_dev;
''')
    text = replace_one(text, '        .core_reset_n(core_reset_n), .irq_out(pl_ps_irq0)\n', '''        .mouse_csr_write(mouse_csr_write), .mouse_csr_waddr(mouse_csr_waddr),
        .mouse_csr_wdata(mouse_csr_wdata), .mouse_csr_wstrb(mouse_csr_wstrb),
        .mouse_csr_raddr(mouse_csr_raddr), .mouse_csr_rdata(mouse_csr_rdata),
        .core_reset_n(core_reset_n), .irq_out(pl_ps_irq0)
''')
    anchor = '    ven_ddram_axi #(.MEM_BASE(MEM_BASE))'
    text = replace_one(text, anchor, '''    // Management ownership survives guest reset long enough to expose its
    // generation. The actual device uses the 8042's guest reset domain.
    ven_ps2_mailbox u_mouse_mailbox (
        .clk(clk), .rst_n(resetn), .guest_reset(soc_reset),
        .csr_write(mouse_csr_write), .csr_waddr(mouse_csr_waddr),
        .csr_wdata(mouse_csr_wdata), .csr_wstrb(mouse_csr_wstrb),
        .csr_raddr(mouse_csr_raddr), .csr_rdata(mouse_csr_rdata),
        .tx_valid(mouse_tx_valid), .tx_data(mouse_tx_data), .tx_ready(mouse_tx_ready),
        .tx_done(mouse_tx_done), .tx_aborted(mouse_tx_aborted),
        .rx_valid(mouse_rx_valid), .rx_data(mouse_rx_data), .rx_error(mouse_rx_error),
        .rx_ready(mouse_rx_ready), .rx_aborted(mouse_rx_aborted)
    );
    ven_ps2_device #(.CLK_HZ(CLK_HZ)) u_ps2_mouse_device (
        .clk(clk), .rst_n(~soc_reset),
        .tx_valid(mouse_tx_valid), .tx_data(mouse_tx_data), .tx_ready(mouse_tx_ready),
        .tx_done(mouse_tx_done), .tx_aborted(mouse_tx_aborted),
        .rx_valid(mouse_rx_valid), .rx_data(mouse_rx_data), .rx_error(mouse_rx_error),
        .rx_ready(mouse_rx_ready), .rx_aborted(mouse_rx_aborted),
        .host_clk_release(ps2_mouseclk_host), .host_dat_release(ps2_mousedat_host),
        .dev_clk_release(ps2_mouseclk_dev), .dev_dat_release(ps2_mousedat_dev)
    );

''' + anchor)
    text = replace_one(text,
        "        .ps2_mouseclk_in(1'b1), .ps2_mousedat_in(1'b1), .ps2_mouseclk_out(), .ps2_mousedat_out(), .ps2_reset_n(),",
        '''        .ps2_mouseclk_in(ps2_mouseclk_host & ps2_mouseclk_dev),
        .ps2_mousedat_in(ps2_mousedat_host & ps2_mousedat_dev),
        .ps2_mouseclk_out(ps2_mouseclk_host), .ps2_mousedat_out(ps2_mousedat_host), .ps2_reset_n(),''')
    return text


def project(text):
    return replace_one(text, 'src/ven_ps2_kbd_inject.v src/clk_div32.v',
                       'src/ven_ps2_kbd_inject.v src/ven_ps2_device.sv src/ven_ps2_mailbox.sv src/clk_div32.v')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flow-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
    assert __debug__ and scratch == Path('/home/yukidama/external/tmp').resolve(strict=True)
    assert scratch.stat().st_dev != repo.stat().st_dev and shutil.disk_usage(scratch).free > 2*1024**3
    source = args.flow_root.resolve(strict=True)
    out = args.output.resolve(strict=True)
    assert out.parent == scratch and not list(out.iterdir()) and out != source
    pins, outputs = {}, {}
    transforms = {'src/ven_mgmt_axil.v': management, 'src/rk_ao486_system_pl.v': wrapper,
                  'hw/create_project.tcl': project}
    for name, digest in BASE.items():
        path = source / name
        data = path.read_bytes()
        assert hashlib.sha256(data).hexdigest() == digest, name
        pins[str(path)] = digest
        outputs[name] = transforms[name](data.decode()).encode()
    for name in ('ven_ps2_device.sv', 'ven_ps2_mailbox.sv'):
        path = repo / 'fpga' / name
        data = path.read_bytes()
        pins[str(path)] = hashlib.sha256(data).hexdigest()
        outputs['src/' + name] = data
    pins[str(Path(__file__).resolve())] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    for name, data in outputs.items():
        target = out / name
        target.parent.mkdir(exist_ok=True)
        with target.open('xb') as stream:
            stream.write(data)
    assert all(hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest for path,digest in pins.items())
    receipt = {'kind': 'PS2_MOUSE_CSR_SOURCE_OVERLAY', 'physical_board': False, 'integrated_candidate': False,
               'input_pins': pins, 'files': {name: hashlib.sha256(data).hexdigest() for name,data in outputs.items()},
               'csr_base': '0x400', 'counter_bits': 32, 'core_rtl_changed': False,
               'warning': 'Overlay only: requires source-matched export, validation and implementation.'}
    with (out / 'prepared.json').open('x') as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print(out)


if __name__ == '__main__':
    main()
