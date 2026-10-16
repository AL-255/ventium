#!/usr/bin/env python3
"""Prepare, never build/run, a host-only live-keyboard derivative.

No RTL/define/guest changes. Full-PC execution and mouse motion remain unqualified.
The original frozen model and native evidence must never be modified in place.
"""
import hashlib
import json
import os
from pathlib import Path

ROOT = Path('/home/yukidama/external/tmp/ventium-fprem-sequence.iSZ9BAj4')
PARENT = ROOT / 'v-result-carry-soc-r1'
MAIN = 'source/ao486-sim/ven/sim_v_result_carry_9e34e5ace2f2.cpp'
MAIN_SHA = 'f5045f6adce56edcdc011954b2eb28fa9cb31cb5524795d9e837eb9fd567e71d'
PS2 = 'source/3rd-party/ao486_MiSTer/rtl/soc/ps2.v'
PS2_SHA = '2ee3b64fc24875b3aaca0e6296a2514161f19cef5e6f79aa90923ca06f1846da'
INPUT_SHA = 'e80b12817951e39eaf74d6830cf020c879a513bb00bdaf72ecd0e9544ef454eb'
HERE = Path(__file__).resolve().parent


def sha(data):
    return hashlib.sha256(data).hexdigest()


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('host integration anchor missing or repeated: ' + old[:90])
    return text.replace(old, new, 1)


def transform(text):
    if sha(text.encode()) != MAIN_SHA:
        raise ValueError('parent main source changed')
    text = once(text, '#include "verilated.h"', '''#include "verilated.h"
#include "pc_keyboard_input.h"
#include <memory>
#include <cstdlib>
static std::unique_ptr<ven_ui::Input> g_ui;
static const char *g_ui_fifo = nullptr;
static unsigned g_ui_captures = 0;
static void ui_check() {
    if (g_ui && g_ui->failed()) {
        fprintf(stderr, "[UI-FAILED] controller/input evidence failed; no replay\\n");
        std::exit(2);
    }
}''')
    text = once(text, 'static void dump_fb_frame(int n) {',
                'static bool dump_fb_path(const char *path, bool exclusive) {')
    text = once(text,
                'if (!R->system__DOT__vga__DOT__attrib_graphic_mode) return;',
                'if (!R->system__DOT__vga__DOT__attrib_graphic_mode) return false;')
    text = once(text, '''    char path[300];
    snprintf(path, sizeof path, "%s_%05d.ppm", g_fb_out, n);
    FILE *f = fopen(path, "wb"); if (!f) return;''',
                '    FILE *f = fopen(path, exclusive ? "wbx" : "wb"); if (!f) return false;')
    text = once(text, '''    fclose(f);
    fprintf(stderr, "[FBCAP] %s mode=%s chain4=%d pel2=%d start=%u nz=%ld\\n", path, modestr, chain4, pel2, start, nz);
}''', '''    if (!ven_ui::complete_raw_file(f, true)) return false;
    fprintf(stderr, "[FBCAP] %s mode=%s chain4=%d pel2=%d start=%u nz=%ld\\n", path, modestr, chain4, pel2, start, nz);
    return true;
}
static void dump_fb_frame(int n) {
    char path[300];
    const int length = snprintf(path, sizeof path, "%s_%05d.ppm", g_fb_out, n);
    if (length < 0 || size_t(length) >= sizeof path || !dump_fb_path(path, false))
        fprintf(stderr, "[FBCAP-ERROR] frame=%d no_publication=1\\n", n);
}
static void ui_capture() {
    if (!g_ui) return;
    uint64_t id = 0;
    if (!g_ui->capture_ready(id)) return;
    if (!in_graphics_mode()) {
        g_ui->capture_result(id, main_time, nullptr, false);
        return;
    }
    // IDs are monotonic; exclusive creation prevents overwriting evidence.
    // Raw existing VGA conversion only: no color/size/guest-state changes.
    const std::string fifo(g_ui_fifo);
    const std::string path = fifo.substr(0, fifo.find_last_of('/')) +
        "/capture_" + std::to_string(id) + ".ppm";
    if (g_ui_captures >= 64 || !dump_fb_path(path.c_str(), true))
        g_ui->capture_write_failed(main_time);
    else {
        ++g_ui_captures;
        g_ui->capture_result(id, main_time, path.c_str(), true);
    }
    ui_check();
}''')
    text = once(text, '    set_clocks(0);', '''    if (g_ui) {
        if (!(main_time & 4095)) g_ui->poll(main_time);
        ven_ui::pc_keyboard_drive(*g_ui, main_time, *top);
        ui_check();
    }
    set_clocks(0);''')
    text = once(text, '    set_clocks(1); step_vga_clock(); top->eval();', '''    ven_ui::PcKeyboardEdge ui_edge;
    if (g_ui) {
        ui_edge = ven_ui::pc_keyboard_before(*g_ui, main_time, *top->rootp, top->reset);
        ui_check();
    }
    set_clocks(1); step_vga_clock(); top->eval();
    if (g_ui) {
        ven_ui::pc_keyboard_after(*g_ui, main_time, *top->rootp, ui_edge);
        ui_check();
    }''')
    text = once(text, '    Verilated::commandArgs(argc, argv);', '''    Verilated::commandArgs(argc, argv);
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--ui-fifo")) {
            if (g_ui_fifo || i+1 == argc || argv[i+1][0] != '/') {
                fprintf(stderr, "--ui-fifo requires one absolute endpoint path\\n");
                return 2;
            }
            g_ui_fifo = argv[++i];
        }
    }
    if (g_ui_fifo) for (int i = 1; i < argc; ++i) {
        if (ven_ui::forbidden_ui_option(argv[i]) ||
            !strncmp(argv[i], "--ven-break", 11)) {
            fprintf(stderr, "live input excludes legacy keyboard, snapshots and breakpoints\\n");
            return 2;
        }
    }''')
    text = once(text,
                '        if (!strcmp(argv[i], "--cycles") && i+1<argc)',
                '''        if (!strcmp(argv[i], "--ui-fifo")) { ++i; continue; }
        if (!strcmp(argv[i], "--cycles") && i+1<argc)''')
    text = once(text, '    top = new Vsystem;', '''    if (g_ui_fifo) {
        try {
            if (g_clock_rate < 50000) throw std::runtime_error("invalid_ui_clock");
            g_ui = std::make_unique<ven_ui::Input>(ven_ui::Timing::ordinary(g_clock_rate));
            g_ui->open_fifo(g_ui_fifo);
        } catch (const std::exception &error) {
            fprintf(stderr, "[UI-SETUP-ERROR] %s\\n", error.what());
            return 2;
        }
    }
    top = new Vsystem;''')
    text = once(text, '        ps2_kb_drive();   // inject queued keystrokes (no-op unless --kb given)',
                '''        ui_capture(); // live command; raw pixels, no UI success inference
        ps2_kb_drive();   // inject queued keystrokes (no-op unless --kb given)''')
    text = once(text, '    top->final(); delete top; free(ddr);', '''    if (g_ui && !g_ui->finish(main_time)) stop_request_exit = 2;
    top->final(); delete top; free(ddr);''')
    return text


def prepare(out):
    external = Path('/home/yukidama/external/tmp').resolve(strict=True)
    if not os.access(external, os.W_OK) or not out.parent.resolve().is_relative_to(external):
        raise ValueError('output must be in mounted writable external/tmp')
    if external.stat().st_dev == Path('/').stat().st_dev:
        raise ValueError('external filesystem not mounted')
    main = (PARENT / MAIN).read_bytes()
    ps2 = (PARENT / PS2).read_bytes()
    protocol = (HERE / 'ui_input_host.h').read_bytes()
    if sha(ps2) != PS2_SHA or sha(protocol) != INPUT_SHA:
        raise ValueError('controller or qualified protocol changed')
    output = transform(main.decode()).encode()
    out.mkdir(mode=0o700)  # Exclusive new directory, never mutate an old run.
    name = 'sim_pc_live_input_' + sha(output)[:12] + '.cpp'
    (out / name).write_bytes(output)
    for header in ('pc_keyboard_input.h', 'ui_input_host.h'):
        (out / header).write_bytes((HERE / header).read_bytes())
    receipt = dict(parent=str(PARENT), parent_main_sha256=MAIN_SHA,
                   ps2_sha256=PS2_SHA, protocol_sha256=INPUT_SHA,
                   generated_main=name, generated_main_sha256=sha(output),
                   rtl_changes=[], define_changes=[], compiled=False,
                   gameplay_ipc=None, mouse_motion=False, acceptance=False)
    (out / 'prepared.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.out), indent=2))
