// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Standalone host stubs only: no Verilator, DUT evaluations, or guest memory.
#include "../ao486-sim/ven/cache_source_probe.h"
#include "../ao486-sim/ven/l1_fill_probe.h"
#include <array>
#include <cstring>
#include <stdexcept>
#include <string>

#define L1(name) system__DOT__u_cpu__DOT__u_core__DOT__u_l1axi__DOT__##name
#define D(name) L1(u_l1d__DOT__##name)
#define C(name) system__DOT__u_cpu__DOT__u_core__DOT__u_core__DOT__##name
#define T(name) system__DOT__u_cpu__DOT__u_core__DOT__##name
#define B(bank, name) D(g_banked_read__BRA__##bank##__KET____DOT__##name)
#define SCALAR(name) uint32_t name = 0
#define BANK(bank) SCALAR(B(bank, wr_row)); SCALAR(B(bank, wr_mask)); \
    SCALAR(B(bank, wr_data)); std::array<uint32_t, BankWords> B(bank, data){}

template<size_t Sets = 128, size_t Ways = 2, size_t BankWords = 256,
         size_t RawWords = 8, size_t WindowWords = 16>
struct Model {
    SCALAR(L1(l1d_c_req)); SCALAR(L1(l1d_c_ack)); SCALAR(L1(l1d_cacheable));
    SCALAR(L1(m_ack)); SCALAR(L1(m_addr)); SCALAR(L1(m_rdata));
    SCALAR(C(bd_addr)); SCALAR(C(bd_we));
    SCALAR(T(core_mem_wstrb)); SCALAR(T(core_mem_wdata)); SCALAR(T(core_mem_code));
    std::array<std::array<uint32_t, Ways>, Sets> D(dc_tag){};
    std::array<std::array<uint32_t, Ways>, Sets> D(dc_val){};
    std::array<uint32_t, RawWords> D(rd_line_raw){};
    std::array<uint32_t, WindowWords> D(rd_window_q){};
    std::array<uint32_t, 8> D(shadow_line_q){};
    std::array<uint32_t, 8> D(code_line_q){};
    SCALAR(D(st)); SCALAR(D(hit0)); SCALAR(D(hit1)); SCALAR(D(rd_hit));
    SCALAR(D(rd_armed)); SCALAR(D(rd_match)); SCALAR(D(rd_code_q));
    SCALAR(D(rd_full_line_q)); SCALAR(D(rd_addr_q)); SCALAR(D(do_rd_cap));
    SCALAR(D(window_valid_q)); SCALAR(D(window_reuse));
    SCALAR(D(shadow_valid_q)); SCALAR(D(shadow_reuse)); SCALAR(D(shadow_line_addr_q));
    SCALAR(D(code_access)); SCALAR(D(code_valid_q)); SCALAR(D(code_line_tag_q));
    SCALAR(D(code_fill_q)); SCALAR(D(fill_forward_hit)); SCALAR(D(fill_independent_hit));
    SCALAR(D(early_armed)); SCALAR(D(early_match)); SCALAR(D(early_addr_q));
    SCALAR(D(early_rdata_q)); SCALAR(D(early_wstrb_q)); SCALAR(D(early_code_q));
    SCALAR(D(fbase)); SCALAR(D(fset)); SCALAR(D(fway)); SCALAR(D(ftag)); SCALAR(D(fw));
    SCALAR(D(fill_word)); SCALAR(D(fill_word_valid)); SCALAR(D(fill_poison));
    SCALAR(D(bypass_q)); SCALAR(D(xline)); SCALAR(D(bank_fill_we));
    SCALAR(D(bank_store_we)); SCALAR(D(bank_pair_store_we));
    BANK(0); BANK(1); BANK(2); BANK(3); BANK(4); BANK(5); BANK(6); BANK(7);
};
using Full = Model<>;
struct Missing {};
struct WithFlush : Full { SCALAR(L1(__Vcellinp__u_l1d__flush_all)); };
#undef SCALAR
#undef BANK

static unsigned checks = 0;
static void check(bool condition, const char *label) {
    ++checks;
    if (!condition) throw std::runtime_error(label);
}
static std::string read_output(FILE *f) {
    std::fflush(f);
    std::rewind(f);
    std::string result;
    char buffer[1024];
    while (const size_t count = std::fread(buffer, 1, sizeof(buffer), f))
        result.append(buffer, count);
    return result;
}
template<class Root>
static void geometry_rejected(const Root &r, bool event_rejected) {
    FILE *f = std::tmpfile();
    check(f != nullptr, "tmpfile geometry");
    check(!ven_cache_source_probe(f, r, 1, 0xC0631, 0), "unsupported snapshot geometry");
    check(read_output(f).empty(), "unsupported snapshot emits nothing");
    if (event_rejected) check(ven_cache_line_event(r, 0xC0620, 0) == -1,
                              "unsupported event geometry");
    std::fclose(f);
}
static void test_geometry() {
    geometry_rejected(Missing{}, true);
    geometry_rejected(Model<127>{}, true);
    geometry_rejected(Model<128, 1>{}, true);
    geometry_rejected(Model<128, 3>{}, true);
    geometry_rejected(Model<128, 2, 255>{}, false);
    geometry_rejected(Model<128, 2, 256, 7>{}, false);
    geometry_rejected(Model<128, 2, 256, 8, 15>{}, false);
    check(!ven_cache_source_probe(nullptr, Full{}, 0, 0, 0), "null file rejected");
}
static void test_fill_events() {
    Full r;
    const uint32_t line = 0xC0620;
    r.D(rd_hit) = r.D(hit0) = r.L1(l1d_c_req) = r.L1(l1d_c_ack) = 1;
    check(ven_cache_line_event(r, line, 0) == 0, "read hit is not mutation");
    r.D(st) = 1; r.D(fbase) = line; r.L1(m_ack) = 1;
    check(ven_cache_line_event(r, line + 17, 0) == 1, "accepted fill normalizes target");
    r.D(code_fill_q) = 1;
    check(ven_cache_line_event(r, line, 0) == 1, "code fill remains observed");
    r.D(bypass_q) = 1;
    check(ven_cache_line_event(r, line, 0) == 1, "bypass fill remains observed");
    r.D(fbase) = line + 32;
    check(ven_cache_line_event(r, line, 0) == 0, "non-target fill ignored");
    r.D(fbase) = line; r.L1(m_ack) = 0;
    check(ven_cache_line_event(r, line, 0) == 0, "unaccepted fill ignored");
    r.L1(m_ack) = 1; r.D(st) = 0;
    check(ven_cache_line_event(r, line, 0) == 0, "idle-high ACK ignored");
    r.D(st) = 2;
    check(ven_cache_line_event(r, line, 0) == 0, "other FSM state ACK ignored");
}
static void test_store_events() {
    Full r;
    const uint32_t line = 0xC0620;
    r.L1(l1d_c_req) = r.L1(l1d_c_ack) = r.C(bd_we) = 1;
    r.C(bd_addr) = line + 17; r.T(core_mem_wstrb) = 1;
    check(ven_cache_line_event(r, line, 0) == 1, "accepted ROM-address byte store observed");
    r.T(core_mem_wstrb) = 0;
    check(ven_cache_line_event(r, line, 0) == 0, "zero strobes ignored");
    r.C(bd_addr) = line - 2; r.T(core_mem_wstrb) = 3;
    check(ven_cache_line_event(r, line, 0) == 0, "disabled cross-line bytes ignored");
    r.T(core_mem_wstrb) = 4;
    check(ven_cache_line_event(r, line, 0) == 1, "enabled cross-line byte observed");
    r.C(bd_addr) = line + 31; r.T(core_mem_wstrb) = 2;
    check(ven_cache_line_event(r, line, 0) == 0, "enabled next-line byte not target");
    check(ven_cache_line_event(r, line + 32, 0) == 1, "enabled next-line byte matches next line");
    r.C(bd_addr) = line; r.T(core_mem_wstrb) = 15;
    r.L1(l1d_c_req) = 0;
    check(ven_cache_line_event(r, line, 0) == 0, "store without request ignored");
    r.L1(l1d_c_req) = 1; r.L1(l1d_c_ack) = 0;
    check(ven_cache_line_event(r, line, 0) == 0, "store without ACK ignored");
    r.L1(l1d_c_ack) = 1; r.C(bd_we) = 0;
    check(ven_cache_line_event(r, line, 0) == 0, "read acceptance ignored");
    r.C(bd_we) = 1; r.C(bd_addr) = 0xFFFFFFFF; r.T(core_mem_wstrb) = 2;
    check(ven_cache_line_event(r, 0, 0) == 1, "physical address wraps at32 bits");
}
static void test_bank_events() {
    const uint32_t line = 0xC0620;
    const unsigned set = (line >> 5) & 127;
    Full r;
    r.D(dc_tag)[set][0] = line >> 12;
    r.D(dc_val)[set][0] = 1;
    r.B(0, wr_row) = set << 1; r.B(0, wr_mask) = 1;
    check(ven_cache_line_event(r, line, 0) == 1, "resident way0 bank mutation");
    r.D(dc_val)[set][0] = 0;
    check(ven_cache_line_event(r, line, 0) == 0, "invalid tag is not resident");
    r.D(dc_val)[set][0] = 1; ++r.D(dc_tag)[set][0];
    check(ven_cache_line_event(r, line, 0) == 0, "same-set different-tag ignored");
    r.D(dc_tag)[set][0] = line >> 12; r.B(0, wr_mask) = 0;
    check(ven_cache_line_event(r, line, 0) == 0, "bank write with zero mask ignored");
    r.B(0, wr_mask) = 1; r.B(0, wr_row) = 256;
    check(ven_cache_line_event(r, line, 0) == 0, "out-of-range bank row ignored");
    r.B(0, wr_row) = (set + 1) << 1;
    check(ven_cache_line_event(r, line, 0) == 0, "other bank set ignored");
    r.B(0, wr_mask) = 0;
    r.D(dc_val)[set][1] = 1; r.D(dc_tag)[set][1] = line >> 12;
    r.D(bank_pair_store_we) = 1;
#define CHECK_BANK(bank) do { \
    r.B(bank, wr_row) = (set << 1) | 1; r.B(bank, wr_mask) = 8; \
    check(ven_cache_line_event(r, line, 0) == 1, "paired resident bank/way1 mutation"); \
    r.B(bank, wr_mask) = 0; \
} while (false)
    CHECK_BANK(0); CHECK_BANK(1); CHECK_BANK(2); CHECK_BANK(3);
    CHECK_BANK(4); CHECK_BANK(5); CHECK_BANK(6); CHECK_BANK(7);
#undef CHECK_BANK
    check(ven_cache_line_event(r, line, 0) == 0,
          "pair flag alone is not inferred V-store acceptance");
}
static void test_output_and_neutrality() {
    Full r;
    const unsigned set = 0x31;
    r.D(dc_tag)[set][0] = 0xC0; r.D(dc_val)[set][0] = 1;
    r.D(dc_tag)[set][1] = 0x123; r.D(dc_val)[set][1] = 0;
    r.C(bd_addr) = 0xC0631; r.T(core_mem_wstrb) = 4;
    r.D(fbase) = 0xC0620; r.D(fset) = set; r.D(fway) = 1;
    r.D(shadow_line_addr_q) = r.D(code_line_tag_q) = 0x6031;
    r.D(early_addr_q) = 0xC0632; r.D(early_rdata_q) = 0xAABBCCDD;
    for (unsigned i = 0; i < 8; ++i) {
        r.D(rd_line_raw)[i] = 0x10000000 + i;
        r.D(shadow_line_q)[i] = 0x30000000 + i;
        r.D(code_line_q)[i] = 0x40000000 + i;
    }
    for (unsigned i = 0; i < 16; ++i) r.D(rd_window_q)[i] = 0x20000000 + i;
#define SET_BANK(bank) r.B(bank, data)[0x62] = 0x50000000 + bank; \
    r.B(bank, data)[0x63] = 0x60000000 + bank; \
    r.B(bank, wr_row) = 0x63; r.B(bank, wr_mask) = 2; r.B(bank, wr_data) = 0x70000000 + bank
    SET_BANK(0); SET_BANK(1); SET_BANK(2); SET_BANK(3);
    SET_BANK(4); SET_BANK(5); SET_BANK(6); SET_BANK(7);
#undef SET_BANK
    std::array<unsigned char, sizeof(r)> before{};
    std::memcpy(before.data(), &r, sizeof(r));
    FILE *f = std::tmpfile(); check(f != nullptr, "tmpfile output");
    check(ven_cache_source_probe(f, r, 123456, 0xC0631, 0), "supported snapshot emits");
    const std::string out = read_output(f);
    check(std::memcmp(before.data(), &r, sizeof(r)) == 0, "observer makes no model writes");
    check(out.find("addr=000c0631 set=31 tag=000c0 bank=4 lane=1") != std::string::npos,
          "physical set/bank/lane mapping");
    check(out.find("tag0=000c0 val0=1 tag1=00123 val1=0") != std::string::npos,
          "both tag ways printed");
    check(out.find("way=0 row=62 words=50000000,50000001,50000002,50000003,50000004,50000005,50000006,50000007") != std::string::npos,
          "way0 row is set-times2 not way-times128");
    check(out.find("way=1 row=63 words=60000000,60000001,60000002,60000003,60000004,60000005,60000006,60000007") != std::string::npos,
          "way1 exact bank words");
    check(out.find("kind=raw words=10000000,10000001") != std::string::npos, "raw words printed");
    check(out.find("2000000f") != std::string::npos, "full16-word window printed");
    check(out.find("kind=shadow words=30000000") != std::string::npos, "shadow words printed");
    check(out.find("kind=code words=40000000") != std::string::npos, "code words printed");
    check(out.find("shadow_line=0006031 code_line=0006031") != std::string::npos, "saved line identities");
    check(out.find("early_addr=000c0632 early_data=aabbccdd") != std::string::npos, "early owner printed");
    check(out.find("fill_addr=000c0620 fill_set=31 fill_way=1") != std::string::npos, "fill owner printed");
    check(out.find("7:63/2/70000007") != std::string::npos, "all bank write metadata printed");
    unsigned lines = 0;
    for (char ch : out) lines += ch == '\n';
    check(lines == 9 && out.size() < 4096, "one snapshot has bounded9 records under4KiB");
    std::fclose(f);
}
static void test_optional_flush() {
    Full r;
    FILE *f = std::tmpfile(); check(f != nullptr, "tmpfile flush");
    check(ven_l1_flush_observation(r, 0) == -1, "missing flush reports unavailable");
    check(ven_l1_fill_probe(f, r, 1, 0), "missing flush does not disable whole probe");
    check(read_output(f).find("flush=-1") != std::string::npos, "unavailable flush printed honestly");
    std::fclose(f);
    WithFlush present;
    check(ven_l1_flush_observation(present, 0) == 0, "actual flush0 preserved");
    present.L1(__Vcellinp__u_l1d__flush_all) = 1;
    check(ven_l1_flush_observation(present, 0) == 1, "actual flush1 preserved");
    check(ven_l1_flush_observation(Missing{}, 0) == -1, "unsupported model flush unavailable");
}
int main() {
    try {
        test_geometry(); test_fill_events(); test_store_events(); test_bank_events();
        test_output_and_neutrality(); test_optional_flush();
        std::printf("CACHE-SOURCE-HOST-OK checks=%u\n", checks);
        return 0;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "CACHE-SOURCE-HOST-FAIL check=%u: %s\n", checks, e.what());
        return 1;
    }
}
#undef B
#undef T
#undef C
#undef D
#undef L1
