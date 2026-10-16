// Read-only bindings for the frozen ao486 system's real PS/2 controller.
// VEN_KBC_FAST + VEN_KBD_AUTOACK are required by the source-pinned adapter.
// The only DUT writes below are ordinary external keyboard clock/data pins.
#ifndef VENTIUM_PC_KEYBOARD_INPUT_H
#define VENTIUM_PC_KEYBOARD_INPUT_H

#include "ui_input_host.h"

namespace ven_ui {

struct PcKeyboardEdge {
    ReceiveProof proof;
    bool consumed = false;
    uint8_t consumed_value = 0;
};

template<class Top>
void pc_keyboard_drive(Input &input, uint64_t cycle, Top &top) {
    const auto &r = *top.rootp;
    const Lines lines = input.drive(cycle, top.reset, top.ps2_kbclk_out,
        top.ps2_kbdat_out, r.system__DOT__ps2__DOT__keyb_state == 0);
    top.ps2_kbclk_in = lines.clock && top.ps2_kbclk_out;
    top.ps2_kbdat_in = lines.data && top.ps2_kbdat_out;
}

// Call after the ordinary low-clock evaluation, immediately before the real
// rising edge. No eval(), FIFO mutation, fabricated ACK, or CPU-state access.
template<class Root>
PcKeyboardEdge pc_keyboard_before(Input &input, uint64_t cycle,
                                  const Root &r, bool reset) {
#define K(name) r.system__DOT__ps2__DOT__##name
    input.prefix_context_before(cycle, K(translate), K(keyb_translate_escape),
        reset || K(cmd_self_test), K(keyb_timeout) == 1);
    PcKeyboardEdge edge;
    auto &p = edge.proof;
    p.final = K(keyb_recv_final); p.reset = reset; p.clear = K(cmd_self_test);
    p.translated = K(translate); p.escape_before = K(keyb_translate_escape);
    p.autoack = K(wtk_q); p.reply = K(ps2_kb_reply_done);
    p.write_request = K(kb_fifo_wrreq); p.full = K(keyb_fifo_full);
    p.read_request = K(__Vcellinp__keyb_fifo__rdreq);
    p.raw = K(keyb_recv_buffer);
    p.translated_value = p.translated ?
        ((unsigned(p.escape_before) << 7) | K(trans)) : p.raw;
    // These two combinational wires are optimized out of the full-PC model.
    // This is exactly the pinned ps2.v mux (AUTOACK > reply > scan), not
    // acceptance inferred from the requested byte. Post-edge index AND actual
    // FIFO memory must independently confirm the selected byte was stored.
    p.produced_value = p.autoack ? 0xfa :
        (p.reply ? K(keyb_reply) : p.translated_value);
    p.old_write_index = K(keyb_fifo__DOT__wr_index);
    edge.consumed = p.read_request && !K(keyb_fifo_empty);
    edge.consumed_value = K(keyb_fifo_q);
#undef K
    return edge;
}

template<class Root>
void pc_keyboard_after(Input &input, uint64_t cycle, const Root &r,
                       PcKeyboardEdge edge) {
#define K(name) r.system__DOT__ps2__DOT__##name
    auto &p = edge.proof;
    if (p.old_write_index >= 64)
        throw std::runtime_error("ui_keyboard_fifo_index_out_of_range");
    p.new_write_index = K(keyb_fifo__DOT__wr_index);
    p.post_memory_at_old_write_index = K(keyb_fifo__DOT__mem)[p.old_write_index];
    p.escape_after = K(keyb_translate_escape);
    input.controller_reset_edge(cycle, p.reset || p.clear);
    input.accepted_edge(cycle, p);
    input.guest_read_edge(cycle, edge.consumed && !p.reset && !p.clear,
                          edge.consumed_value);
#undef K
}

} // namespace ven_ui
#endif
