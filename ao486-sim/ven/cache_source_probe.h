#pragma once
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Passive generated-model observations, NOT an architectural trace producer.
// No evaluations, memory peeks, model writes, callbacks or retained history.
#include <cstdint>
#include <cstdio>

#define VEN_CS_L1(name) r.system__DOT__u_cpu__DOT__u_core__DOT__u_l1axi__DOT__##name
#define VEN_CS_D(name) VEN_CS_L1(u_l1d__DOT__##name)
#define VEN_CS_C(name) r.system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##name
#define VEN_CS_T(name) r.system__DOT__u_cpu__DOT__u_core__DOT__##name
#define VEN_CS_B(bank, name) VEN_CS_D(g_banked_read__BRA__##bank##__KET____DOT__##name)
#define VEN_CS_WRITE_FIELDS(bank) (void)VEN_CS_B(bank, wr_row), (void)VEN_CS_B(bank, wr_mask)
#define VEN_CS_BANK_FIELDS(bank) VEN_CS_WRITE_FIELDS(bank), \
    (void)VEN_CS_B(bank, wr_data), (void)VEN_CS_B(bank, data).size()

// Returns -1 for unsupported generated hierarchy/geometry, 0 for no relevant
// mutation, 1 for an accepted fill/store or resident target-bank mutation.
// Caller owns the time/event cap. Ordinary read hits are not events here.
// mutation_only suppresses code-buffer/bypass fills and requires actual D-bank
// fill enables; accepted stores and resident-bank writes remain observable.
// Paired V stores are observed through actual resident-bank writes; a V-store
// miss without an available acceptance signal is not inferred from ready.
template<class Root>
auto ven_cache_line_event(const Root &r, uint32_t physical_line, int, bool mutation_only = false)
    -> decltype((void)VEN_CS_D(st), (void)VEN_CS_D(fbase),
                (void)VEN_CS_D(code_fill_q), (void)VEN_CS_D(bypass_q),
                (void)VEN_CS_D(bank_fill_we),
                (void)VEN_CS_L1(m_ack), (void)VEN_CS_L1(l1d_c_req),
                (void)VEN_CS_L1(l1d_c_ack), (void)VEN_CS_C(bd_we),
                (void)VEN_CS_C(bd_addr), (void)VEN_CS_T(core_mem_wstrb),
                (void)VEN_CS_D(dc_tag).size(), (void)VEN_CS_D(dc_val).size(),
                (void)VEN_CS_D(dc_tag)[0].size(), (void)VEN_CS_D(dc_val)[0].size(),
                VEN_CS_WRITE_FIELDS(0), VEN_CS_WRITE_FIELDS(1),
                VEN_CS_WRITE_FIELDS(2), VEN_CS_WRITE_FIELDS(3),
                VEN_CS_WRITE_FIELDS(4), VEN_CS_WRITE_FIELDS(5),
                VEN_CS_WRITE_FIELDS(6), VEN_CS_WRITE_FIELDS(7), int()) {
    if (VEN_CS_D(dc_tag).size() != 128 || VEN_CS_D(dc_val).size() != 128 ||
        VEN_CS_D(dc_tag)[0].size() != 2 || VEN_CS_D(dc_val)[0].size() != 2) return -1;
    const uint32_t line = physical_line & ~uint32_t(31);
    if (VEN_CS_L1(m_ack) && VEN_CS_D(st) == 1 &&
        (uint32_t(VEN_CS_D(fbase)) & ~uint32_t(31)) == line &&
        (!mutation_only || (!VEN_CS_D(code_fill_q) && !VEN_CS_D(bypass_q) &&
                            VEN_CS_D(bank_fill_we)))) return 1;
    if (VEN_CS_L1(l1d_c_req) && VEN_CS_C(bd_we) && VEN_CS_L1(l1d_c_ack)) {
        for (unsigned byte = 0; byte < 4; ++byte)
            if ((VEN_CS_T(core_mem_wstrb) & (1u << byte)) &&
                ((uint32_t(VEN_CS_C(bd_addr) + byte) & ~uint32_t(31)) == line)) return 1;
    }
    const unsigned set = (line >> 5) & 127u;
    const uint32_t tag = line >> 12;
#define VEN_CS_BANK_EVENT(bank) do { \
    const unsigned row = unsigned(VEN_CS_B(bank, wr_row)); \
    if (VEN_CS_B(bank, wr_mask) && row < 256 && (row >> 1) == set && \
        VEN_CS_D(dc_val)[set][row & 1] && VEN_CS_D(dc_tag)[set][row & 1] == tag) return 1; \
} while (false)
    VEN_CS_BANK_EVENT(0); VEN_CS_BANK_EVENT(1); VEN_CS_BANK_EVENT(2); VEN_CS_BANK_EVENT(3);
    VEN_CS_BANK_EVENT(4); VEN_CS_BANK_EVENT(5); VEN_CS_BANK_EVENT(6); VEN_CS_BANK_EVENT(7);
#undef VEN_CS_BANK_EVENT
    return 0;
}
template<class Root>
int ven_cache_line_event(const Root &, uint32_t, long, bool = false) { return -1; }

template<class Root>
auto ven_cache_source_probe(FILE *out, const Root &r, uint64_t cycle, uint32_t physical_addr, int)
    -> decltype((void)VEN_CS_L1(l1d_c_req), (void)VEN_CS_L1(l1d_c_ack),
                (void)VEN_CS_L1(l1d_cacheable), (void)VEN_CS_L1(m_ack),
                (void)VEN_CS_L1(m_addr), (void)VEN_CS_L1(m_rdata),
                (void)VEN_CS_C(bd_addr), (void)VEN_CS_C(bd_we),
                (void)VEN_CS_T(core_mem_wstrb), (void)VEN_CS_T(core_mem_wdata),
                (void)VEN_CS_T(core_mem_code),
                (void)VEN_CS_D(dc_tag).size(), (void)VEN_CS_D(dc_val).size(),
                (void)VEN_CS_D(dc_tag)[0].size(), (void)VEN_CS_D(dc_val)[0].size(),
                (void)VEN_CS_D(rd_line_raw).size(), (void)VEN_CS_D(rd_window_q).size(),
                (void)VEN_CS_D(shadow_line_q).size(), (void)VEN_CS_D(code_line_q).size(),
                (void)VEN_CS_D(st), (void)VEN_CS_D(hit0), (void)VEN_CS_D(hit1),
                (void)VEN_CS_D(rd_hit), (void)VEN_CS_D(rd_armed), (void)VEN_CS_D(rd_match),
                (void)VEN_CS_D(rd_code_q), (void)VEN_CS_D(rd_full_line_q),
                (void)VEN_CS_D(rd_addr_q), (void)VEN_CS_D(do_rd_cap),
                (void)VEN_CS_D(window_valid_q), (void)VEN_CS_D(window_reuse),
                (void)VEN_CS_D(shadow_valid_q), (void)VEN_CS_D(shadow_reuse),
                (void)VEN_CS_D(shadow_line_addr_q), (void)VEN_CS_D(code_access),
                (void)VEN_CS_D(code_valid_q), (void)VEN_CS_D(code_line_tag_q),
                (void)VEN_CS_D(code_fill_q), (void)VEN_CS_D(fill_forward_hit),
                (void)VEN_CS_D(fill_independent_hit), (void)VEN_CS_D(early_armed),
                (void)VEN_CS_D(early_match), (void)VEN_CS_D(early_addr_q),
                (void)VEN_CS_D(early_rdata_q), (void)VEN_CS_D(early_wstrb_q),
                (void)VEN_CS_D(early_code_q), (void)VEN_CS_D(fbase),
                (void)VEN_CS_D(fset), (void)VEN_CS_D(fway), (void)VEN_CS_D(ftag),
                (void)VEN_CS_D(fw), (void)VEN_CS_D(fill_word),
                (void)VEN_CS_D(fill_word_valid), (void)VEN_CS_D(fill_poison),
                (void)VEN_CS_D(bypass_q), (void)VEN_CS_D(xline),
                (void)VEN_CS_D(bank_fill_we), (void)VEN_CS_D(bank_store_we),
                (void)VEN_CS_D(bank_pair_store_we),
                VEN_CS_BANK_FIELDS(0), VEN_CS_BANK_FIELDS(1),
                VEN_CS_BANK_FIELDS(2), VEN_CS_BANK_FIELDS(3),
                VEN_CS_BANK_FIELDS(4), VEN_CS_BANK_FIELDS(5),
                VEN_CS_BANK_FIELDS(6), VEN_CS_BANK_FIELDS(7), bool()) {
    if (!out || VEN_CS_D(dc_tag).size() != 128 || VEN_CS_D(dc_val).size() != 128 ||
        VEN_CS_D(dc_tag)[0].size() != 2 || VEN_CS_D(dc_val)[0].size() != 2 ||
        VEN_CS_D(rd_line_raw).size() != 8 || VEN_CS_D(rd_window_q).size() != 16 ||
        VEN_CS_D(shadow_line_q).size() != 8 || VEN_CS_D(code_line_q).size() != 8) return false;
#define VEN_CS_CHECK_BANK(bank) if (VEN_CS_B(bank, data).size() != 256) return false
    VEN_CS_CHECK_BANK(0); VEN_CS_CHECK_BANK(1); VEN_CS_CHECK_BANK(2); VEN_CS_CHECK_BANK(3);
    VEN_CS_CHECK_BANK(4); VEN_CS_CHECK_BANK(5); VEN_CS_CHECK_BANK(6); VEN_CS_CHECK_BANK(7);
#undef VEN_CS_CHECK_BANK
    const unsigned set = (physical_addr >> 5) & 127u;
    const uint32_t tag = physical_addr >> 12;
    std::fprintf(out, "VENCS cyc=%llu addr=%08x set=%02x tag=%05x bank=%u lane=%u "
                 "tag0=%05x val0=%u tag1=%05x val1=%u req=%u ack=%u we=%u "
                 "live_addr=%08x wstrb=%x wdata=%08x code=%u cacheable=%u "
                 "state=%u hit0=%u hit1=%u rd_hit=%u rd_armed=%u rd_match=%u cap=%u "
                 "window=%u/%u shadow=%u/%u code_access=%u code_valid=%u\n",
                 (unsigned long long)cycle, physical_addr, set, tag, (physical_addr >> 2) & 7u,
                 physical_addr & 3u, unsigned(VEN_CS_D(dc_tag)[set][0]),
                 unsigned(VEN_CS_D(dc_val)[set][0]), unsigned(VEN_CS_D(dc_tag)[set][1]),
                 unsigned(VEN_CS_D(dc_val)[set][1]), unsigned(VEN_CS_L1(l1d_c_req)),
                 unsigned(VEN_CS_L1(l1d_c_ack)), unsigned(VEN_CS_C(bd_we)),
                 unsigned(VEN_CS_C(bd_addr)), unsigned(VEN_CS_T(core_mem_wstrb)),
                 unsigned(VEN_CS_T(core_mem_wdata)), unsigned(VEN_CS_T(core_mem_code)),
                 unsigned(VEN_CS_L1(l1d_cacheable)), unsigned(VEN_CS_D(st)),
                 unsigned(VEN_CS_D(hit0)), unsigned(VEN_CS_D(hit1)), unsigned(VEN_CS_D(rd_hit)),
                 unsigned(VEN_CS_D(rd_armed)), unsigned(VEN_CS_D(rd_match)),
                 unsigned(VEN_CS_D(do_rd_cap)), unsigned(VEN_CS_D(window_valid_q)),
                 unsigned(VEN_CS_D(window_reuse)), unsigned(VEN_CS_D(shadow_valid_q)),
                 unsigned(VEN_CS_D(shadow_reuse)), unsigned(VEN_CS_D(code_access)),
                 unsigned(VEN_CS_D(code_valid_q)));
    std::fprintf(out, "VENCS-OWNER cyc=%llu addr=%08x rd_addr=%08x rd_code=%u full=%u "
                 "shadow_line=%07x code_line=%07x early=%u/%u early_addr=%08x "
                 "early_data=%08x early_strb=%x early_code=%u "
                 "fill_addr=%08x fill_set=%02x fill_way=%u fill_tag=%05x fw=%u word=%u "
                 "word_valid=%02x poison=%u bypass=%u code_fill=%u forward=%u under=%u "
                 "m_ack=%u m_addr=%08x m_data=%08x bank_fill=%u bank_store=%u bank_pair=%u xline=%u\n",
                 (unsigned long long)cycle, physical_addr, unsigned(VEN_CS_D(rd_addr_q)),
                 unsigned(VEN_CS_D(rd_code_q)), unsigned(VEN_CS_D(rd_full_line_q)),
                 unsigned(VEN_CS_D(shadow_line_addr_q)), unsigned(VEN_CS_D(code_line_tag_q)),
                 unsigned(VEN_CS_D(early_armed)), unsigned(VEN_CS_D(early_match)),
                 unsigned(VEN_CS_D(early_addr_q)), unsigned(VEN_CS_D(early_rdata_q)),
                 unsigned(VEN_CS_D(early_wstrb_q)), unsigned(VEN_CS_D(early_code_q)),
                 unsigned(VEN_CS_D(fbase)), unsigned(VEN_CS_D(fset)), unsigned(VEN_CS_D(fway)),
                 unsigned(VEN_CS_D(ftag)), unsigned(VEN_CS_D(fw)), unsigned(VEN_CS_D(fill_word)),
                 unsigned(VEN_CS_D(fill_word_valid)), unsigned(VEN_CS_D(fill_poison)),
                 unsigned(VEN_CS_D(bypass_q)), unsigned(VEN_CS_D(code_fill_q)),
                 unsigned(VEN_CS_D(fill_forward_hit)), unsigned(VEN_CS_D(fill_independent_hit)),
                 unsigned(VEN_CS_L1(m_ack)), unsigned(VEN_CS_L1(m_addr)),
                 unsigned(VEN_CS_L1(m_rdata)), unsigned(VEN_CS_D(bank_fill_we)),
                 unsigned(VEN_CS_D(bank_store_we)), unsigned(VEN_CS_D(bank_pair_store_we)),
                 unsigned(VEN_CS_D(xline)));
#define VEN_CS_PRINT_LINE(label, name, count) do { \
    std::fprintf(out, "VENCS-LINE cyc=%llu addr=%08x kind=" label " words=", \
                 (unsigned long long)cycle, physical_addr); \
    for (unsigned word = 0; word < count; ++word) \
        std::fprintf(out, "%s%08x", word ? "," : "", unsigned(VEN_CS_D(name)[word])); \
    std::fputc('\n', out); \
} while (false)
    VEN_CS_PRINT_LINE("raw", rd_line_raw, 8);
    VEN_CS_PRINT_LINE("window", rd_window_q, 16);
    VEN_CS_PRINT_LINE("shadow", shadow_line_q, 8);
    VEN_CS_PRINT_LINE("code", code_line_q, 8);
#undef VEN_CS_PRINT_LINE
    for (unsigned way = 0; way < 2; ++way) {
        const unsigned row = (set << 1) | way;
        std::fprintf(out, "VENCS-BANKS cyc=%llu addr=%08x way=%u row=%02x words=",
                     (unsigned long long)cycle, physical_addr, way, row);
#define VEN_CS_PRINT_BANK(bank) std::fprintf(out, "%s%08x", bank ? "," : "", unsigned(VEN_CS_B(bank, data)[row]))
        VEN_CS_PRINT_BANK(0); VEN_CS_PRINT_BANK(1); VEN_CS_PRINT_BANK(2); VEN_CS_PRINT_BANK(3);
        VEN_CS_PRINT_BANK(4); VEN_CS_PRINT_BANK(5); VEN_CS_PRINT_BANK(6); VEN_CS_PRINT_BANK(7);
#undef VEN_CS_PRINT_BANK
        std::fputc('\n', out);
    }
    std::fprintf(out, "VENCS-WRITES cyc=%llu addr=%08x banks=row/mask/data:",
                 (unsigned long long)cycle, physical_addr);
#define VEN_CS_PRINT_WRITE(bank) std::fprintf(out, " %u:%02x/%x/%08x", bank, \
    unsigned(VEN_CS_B(bank, wr_row)), unsigned(VEN_CS_B(bank, wr_mask)), unsigned(VEN_CS_B(bank, wr_data)))
    VEN_CS_PRINT_WRITE(0); VEN_CS_PRINT_WRITE(1); VEN_CS_PRINT_WRITE(2); VEN_CS_PRINT_WRITE(3);
    VEN_CS_PRINT_WRITE(4); VEN_CS_PRINT_WRITE(5); VEN_CS_PRINT_WRITE(6); VEN_CS_PRINT_WRITE(7);
#undef VEN_CS_PRINT_WRITE
    std::fputc('\n', out);
    return !std::ferror(out);
}
template<class Root>
bool ven_cache_source_probe(FILE *, const Root &, uint64_t, uint32_t, long) { return false; }

#undef VEN_CS_BANK_FIELDS
#undef VEN_CS_WRITE_FIELDS
#undef VEN_CS_B
#undef VEN_CS_T
#undef VEN_CS_C
#undef VEN_CS_D
#undef VEN_CS_L1
