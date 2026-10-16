// Read-only binding for the current-AUX + retained-RX controller proposal.
// Select explicitly; the legacy binding must not infer this from a lost byte.
#ifndef VENTIUM_PC_KEYBOARD_RETAINED_H
#define VENTIUM_PC_KEYBOARD_RETAINED_H

#include "pc_keyboard_input.h"

namespace ven_ui {

template<class Root>
PcKeyboardEdge pc_keyboard_retained_before(Input &input, uint64_t cycle,
                                           const Root &r, bool reset) {
#define K(name) r.system__DOT__ps2__DOT__##name
    input.prefix_context_before(cycle,K(translate),K(keyb_translate_escape),
        reset || K(cmd_self_test),K(keyb_timeout)==1);
    PcKeyboardEdge edge;
    auto &p=edge.proof;
    p.retained_contract=true;
    p.final=K(keyb_recv_final); p.reset=reset; p.clear=K(cmd_self_test);
    p.translated=K(translate); p.escape_before=K(keyb_translate_escape);
    p.autoack=K(wtk_q) || K(kb_ack_pending); p.reply=K(ps2_kb_reply_done);
    p.write_request=K(kb_fifo_wrreq); p.full=K(keyb_fifo_full);
    p.read_request=K(__Vcellinp__keyb_fifo__rdreq);
    p.raw=K(keyb_recv_buffer);
    p.translated_value=p.translated ?
        ((unsigned(p.escape_before)<<7) | K(trans)) : p.raw;
    p.pending_before=K(kb_rx_pending);
    p.pending_value_before=K(kb_rx_pending_data);
    // Combinational aliases can be optimized out of a generated PC class.
    // Reconstruct only the pinned controller's exact scan/ACK/reply mux from
    // observed state, never from the requested byte. Post-edge FIFO index AND
    // actual memory still independently prove each claimed selected write.
    const bool offer=p.pending_before || (p.final && (!p.translated || p.raw!=0xf0));
    p.scan_commit=!p.reset && !p.clear && (!p.full || p.read_request) && offer;
    p.produced_value=offer ? (p.pending_before ? p.pending_value_before : p.translated_value) :
        p.autoack ? 0xfa : K(keyb_reply);
    p.old_write_index=K(keyb_fifo__DOT__wr_index);
    edge.consumed=p.read_request && !K(keyb_fifo_empty);
    edge.consumed_value=K(keyb_fifo_q);
#undef K
    return edge;
}

template<class Root>
void pc_keyboard_retained_after(Input &input, uint64_t cycle, const Root &r,
                                PcKeyboardEdge edge) {
#define K(name) r.system__DOT__ps2__DOT__##name
    auto &p=edge.proof;
    if (p.old_write_index>=64)
        throw std::runtime_error("ui_keyboard_fifo_index_out_of_range");
    p.new_write_index=K(keyb_fifo__DOT__wr_index);
    p.post_memory_at_old_write_index=K(keyb_fifo__DOT__mem)[p.old_write_index];
    p.escape_after=K(keyb_translate_escape);
    p.pending_after=K(kb_rx_pending);
    p.pending_value_after=K(kb_rx_pending_data);
    input.controller_reset_edge(cycle,p.reset || p.clear);
    input.accepted_edge(cycle,p);
    input.guest_read_edge(cycle,edge.consumed && !p.reset && !p.clear,edge.consumed_value);
#undef K
}

} // namespace ven_ui
#endif
