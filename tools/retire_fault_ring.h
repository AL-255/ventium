// Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#ifndef VENTIUM_RETIRE_FAULT_RING_H
#define VENTIUM_RETIRE_FAULT_RING_H

#include <array>
#include <cerrno>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace ven_host {

// Passive diagnostic text, NOT an architectural .vtrace producer. No guest
// memory reads, model evaluation, state writes or native snapshot state here.
struct FaultRingOptions {
    const char *path = nullptr;
    uint64_t start_retire = 0;
    int vector = -1;
    unsigned max_events = 16;
    bool detail_option_seen = false;
};

inline bool fault_ring_unsigned(const char *text, uint64_t limit, uint64_t &out) {
    if (!text || *text < '0' || *text > '9') return false;
    char *end = nullptr;
    errno = 0;
    const unsigned long long value = std::strtoull(text, &end, 0);
    if (errno || !end || *end || value > limit) return false;
    out = value;
    return true;
}

// Return 1 if consumed, 0 if unrelated, -1 for a malformed recognized option.
inline int parse_fault_ring_option(int argc, char **argv, int &i,
                                   FaultRingOptions &options, const char *&error) {
    const char *arg = argv[i];
    const bool path = !std::strcmp(arg, "--ven-fault-ring");
    const bool start = !std::strcmp(arg, "--ven-fault-ring-start");
    const bool vector = !std::strcmp(arg, "--ven-fault-ring-vector");
    const bool events = !std::strcmp(arg, "--ven-fault-ring-events");
    if (!path && !start && !vector && !events) return 0;
    if (++i >= argc) { error = "fault-ring option requires a value"; return -1; }
    if (path) {
        if (!*argv[i] || options.path) {
            error = "--ven-fault-ring requires one nonempty new-file path";
            return -1;
        }
        options.path = argv[i];
        return 1;
    }
    uint64_t value = 0;
    const uint64_t limit = vector ? 255 : events ? 16 : UINT64_MAX;
    if (!fault_ring_unsigned(argv[i], limit, value) || (events && !value)) {
        error = "invalid fault-ring integer (vector 0..255, events 1..16)";
        return -1;
    }
    options.detail_option_seen = true;
    if (start) options.start_retire = value;
    if (vector) options.vector = int(value);
    if (events) options.max_events = unsigned(value);
    return 1;
}

inline const char *validate_fault_ring_options(const FaultRingOptions &options,
                                               bool restoring) {
    if (options.detail_option_seen && !options.path)
        return "fault-ring filters require --ven-fault-ring PATH";
    if (options.path && restoring)
        return "fault-ring requires a cold run; host history is not checkpointed";
    return nullptr;
}

struct FaultCoreEdge {
    uint64_t cycle = 0, retires = 0;
    uint32_t eip = 0, eflags = 0, q_pc = 0, int_src_pc = 0, int_ret_eip = 0;
    uint32_t int_err = 0, iret_eip = 0, iret_eflags = 0;
    uint32_t cr0 = 0, cr2 = 0, cr3 = 0, cr4 = 0;
    uint32_t cur_lin_nat = 0, cur_lin = 0, mem_addr = 0, bd_addr = 0;
    uint32_t mem_rdata = 0, esp_write_data = 0;
    std::array<uint32_t, 8> gpr{}; // eax,ecx,edx,ebx,esp,ebp,esi,edi
    std::array<uint16_t, 6> seg{}; // cs,ss,ds,es,fs,gs
    std::array<uint32_t, 6> base{};
    std::array<uint8_t, 16> ibuf{}; // live fetched buffer, not reconstructed bytes
    uint16_t iret_cs = 0;
    uint8_t state = 0, q_kind = 0, int_vec = 0, int_step = 0, fault_count = 0;
    uint8_t ss_b = 0, int_gate_op16 = 0, int_has_err = 0;
    uint8_t mem_req = 0, mem_we = 0, mem_ack = 0, cur_size = 0;
    uint8_t read_strobes = 0, write_strobes = 0, esp_write_enable = 0;
};

struct FaultRetireSnapshot {
    uint64_t retire = 0, core_n = 0, cycle = 0;
    uint32_t fetch_pc = 0, eflags = 0;
    std::array<uint32_t, 8> gpr{};
    std::array<uint16_t, 6> seg{}; // post-commit selectors, NOT fetch-PC selectors
    FaultCoreEdge pre_edge{};
};

class RetireFaultRing {
public:
    static constexpr size_t retire_capacity = 256, edge_capacity = 64;
    static constexpr unsigned event_capacity = 16;
    static constexpr size_t file_limit = 4 * 1024 * 1024;

    bool open(const FaultRingOptions &options) {
        if (!options.path || output_ || options.max_events < 1 ||
            options.max_events > event_capacity || options.vector < -1 ||
            options.vector > 255) return false;
        // Do not silently overwrite a previous diagnostic or block on a FIFO.
        output_ = std::fopen(options.path, "wx");
        if (!output_) return false;
        options_ = options;
        return line("FAULT-RING v=1 retire_capacity=256 edge_capacity=64 max_events=%u "
                    "max_bytes=%zu start=%llu vector=%d passive=1 "
                    "dpi_pc=fetch_offset dpi_selectors=post_commit "
                    "edge_context=pre_rising effective_vector=registered_delivery\n",
                    options.max_events, file_limit,
                    (unsigned long long)options.start_retire, options.vector);
    }

    bool enabled() const { return output_ && !failed_ && events_ < options_.max_events; }
    bool failed() const { return failed_; }
    unsigned events() const { return events_; }
    size_t bytes() const { return bytes_; }
    size_t retire_count() const { return retire_size_; }
    size_t edge_count() const { return edge_size_; }
    uint64_t epoch() const { return epoch_; }

    void reset(uint8_t count = 0) {
        retire_size_ = retire_next_ = edge_size_ = edge_next_ = 0;
        previous_count_ = count;
        count_known_ = false;
        previous_edge_known_ = false;
        pre_edge_ = {};
        if (!reset_held_) ++epoch_;
        reset_held_ = true;
        // Event/file caps are lifetime limits; reset must not replenish them.
    }

    void prepare(const FaultCoreEdge &edge) {
        if (!enabled()) return;
        reset_held_ = false;
        pre_edge_ = edge;
        if (!count_known_) { previous_count_ = edge.fault_count; count_known_ = true; }
        // Keep actual input-to-edge ACK data and ESP write bus. Waiting requests
        // are recorded once, not on every idle clock; no guest RAM is sampled.
        const bool transition = !previous_edge_known_ || edge.state != previous_edge_.state ||
            edge.seg[0] != previous_edge_.seg[0] || edge.base[0] != previous_edge_.base[0] ||
            edge.mem_req != previous_edge_.mem_req || edge.mem_we != previous_edge_.mem_we ||
            edge.mem_addr != previous_edge_.mem_addr || edge.int_step != previous_edge_.int_step;
        // FSM mem_ack can be idle-high. Only an active request makes it an
        // operand/frame ACK; idle data must not evict useful frame history.
        if ((edge.mem_req && edge.mem_ack) || edge.esp_write_enable || transition) {
            edges_[edge_next_] = edge;
            edge_next_ = (edge_next_ + 1) % edge_capacity;
            if (edge_size_ < edge_capacity) ++edge_size_;
        }
        previous_edge_ = edge;
        previous_edge_known_ = true;
    }

    void retire(FaultRetireSnapshot snapshot) {
        if (!enabled() || reset_held_) return;
        snapshot.pre_edge = pre_edge_;
        retires_[retire_next_] = snapshot;
        retire_next_ = (retire_next_ + 1) % retire_capacity;
        if (retire_size_ < retire_capacity) ++retire_size_;
    }

    void observe_fault(const FaultCoreEdge &after) {
        if (!enabled()) return;
        if (!count_known_) { previous_count_ = after.fault_count; count_known_ = true; return; }
        const uint8_t delta = uint8_t(after.fault_count - previous_count_);
        previous_count_ = after.fault_count;
        if (!delta || after.retires < options_.start_retire ||
            (options_.vector >= 0 && after.int_vec != options_.vector)) return;
        ++events_;
        line("FAULT event=%u epoch=%llu count_delta=%u cycle=%llu retire=%llu "
             "vec=%u source_pc=%08x ret_eip=%08x err=%08x has_err=%u "
             "pre_cs=%04x pre_cs_base=%08x source_linear_pre_cs=%08x "
             "pre_ss=%04x pre_ss_base=%08x pre_ss_b=%u pre_esp=%08x "
             "pre_flags=%08x pre_state=%u post_state=%u histories=%zu,%zu\n",
             events_, (unsigned long long)epoch_, unsigned(delta),
             (unsigned long long)after.cycle, (unsigned long long)after.retires,
             unsigned(after.int_vec), after.int_src_pc, after.int_ret_eip,
             after.int_err, unsigned(after.int_has_err), unsigned(pre_edge_.seg[0]),
             pre_edge_.base[0], uint32_t(pre_edge_.base[0] + after.int_src_pc),
             unsigned(pre_edge_.seg[1]), pre_edge_.base[1], unsigned(pre_edge_.ss_b),
             pre_edge_.gpr[4], pre_edge_.eflags, unsigned(pre_edge_.state),
             unsigned(after.state), retire_size_, edge_size_);
        print_edge("FAULT-PRE", pre_edge_);
        print_edge("FAULT-POST", after);
        for (size_t k = 0; k < retire_size_; ++k) {
            const auto &s = retires_[(retire_next_ + retire_capacity - retire_size_ + k) % retire_capacity];
            line("RETIRE n=%llu core_n=%llu cycle=%llu fetch_pc=%08x post_fl=%08x "
                 "ax=%08x cx=%08x dx=%08x bx=%08x sp=%08x bp=%08x si=%08x di=%08x "
                 "post_cs=%04x post_ss=%04x post_ds=%04x post_es=%04x post_fs=%04x post_gs=%04x "
                 "pre_cs=%04x pre_cs_base=%08x pre_eip=%08x pre_state=%u pre_qpc=%08x\n",
                 (unsigned long long)s.retire, (unsigned long long)s.core_n,
                 (unsigned long long)s.cycle, s.fetch_pc, s.eflags,
                 s.gpr[0], s.gpr[1], s.gpr[2], s.gpr[3], s.gpr[4], s.gpr[5], s.gpr[6], s.gpr[7],
                 unsigned(s.seg[0]), unsigned(s.seg[1]), unsigned(s.seg[2]),
                 unsigned(s.seg[3]), unsigned(s.seg[4]), unsigned(s.seg[5]),
                 unsigned(s.pre_edge.seg[0]), s.pre_edge.base[0], s.pre_edge.eip,
                 unsigned(s.pre_edge.state), s.pre_edge.q_pc);
        }
        for (size_t k = 0; k < edge_size_; ++k)
            print_edge("EDGE", edges_[(edge_next_ + edge_capacity - edge_size_ + k) % edge_capacity]);
        line("FAULT-END event=%u bytes=%zu\n", events_, bytes_);
        if (std::fflush(output_) != 0) failed_ = true;
    }

    bool close() {
        if (output_) {
            line("FAULT-RING-END events=%u bytes=%zu epochs=%llu failed=%u\n",
                 events_, bytes_, (unsigned long long)epoch_, unsigned(failed_));
            if (std::fclose(output_) != 0) failed_ = true;
            output_ = nullptr;
        }
        return !failed_;
    }
    ~RetireFaultRing() { close(); }
    RetireFaultRing() = default;
    RetireFaultRing(const RetireFaultRing &) = delete;
    RetireFaultRing &operator=(const RetireFaultRing &) = delete;

private:
    bool line(const char *format, ...) {
        if (!output_ || failed_) return false;
        char buffer[2048];
        va_list args;
        va_start(args, format);
        const int size = std::vsnprintf(buffer, sizeof(buffer), format, args);
        va_end(args);
        if (size < 0 || size_t(size) >= sizeof(buffer) || size_t(size) > file_limit - bytes_) {
            failed_ = true;
            return false;
        }
        const size_t written = std::fwrite(buffer, 1, size_t(size), output_);
        bytes_ += written;
        if (written != size_t(size)) failed_ = true;
        return !failed_;
    }

    void print_edge(const char *kind, const FaultCoreEdge &e) {
        char bytes[33];
        for (size_t k = 0; k < e.ibuf.size(); ++k)
            std::snprintf(bytes + 2 * k, 3, "%02x", unsigned(e.ibuf[k]));
        line("%s cycle=%llu retire=%llu state=%u eip=%08x qpc=%08x kind=%u fl=%08x "
             "cs=%04x csb=%08x ss=%04x ssb=%08x ss_B=%u ds=%04x dsb=%08x "
             "es=%04x esb=%08x fs=%04x fsb=%08x gs=%04x gsb=%08x "
             "ax=%08x cx=%08x dx=%08x bx=%08x sp=%08x bp=%08x si=%08x di=%08x "
             "cr0=%08x cr2=%08x cr3=%08x cr4=%08x vec=%u src=%08x err=%08x "
             "step=%u gate16=%u iret_ip=%08x iret_cs=%04x iret_fl=%08x "
             "nat=%08x lin=%08x addr=%08x bdaddr=%08x req=%u we=%u ack=%u "
             "size=%u rstrb=%x wstrb=%x rdata=%08x esp_we=%u esp_wd=%08x ibuf=%s\n",
             kind, (unsigned long long)e.cycle, (unsigned long long)e.retires,
             unsigned(e.state), e.eip, e.q_pc, unsigned(e.q_kind), e.eflags,
             unsigned(e.seg[0]), e.base[0], unsigned(e.seg[1]), e.base[1], unsigned(e.ss_b),
             unsigned(e.seg[2]), e.base[2], unsigned(e.seg[3]), e.base[3],
             unsigned(e.seg[4]), e.base[4], unsigned(e.seg[5]), e.base[5],
             e.gpr[0], e.gpr[1], e.gpr[2], e.gpr[3], e.gpr[4], e.gpr[5], e.gpr[6], e.gpr[7],
             e.cr0, e.cr2, e.cr3, e.cr4, unsigned(e.int_vec), e.int_src_pc, e.int_err,
             unsigned(e.int_step), unsigned(e.int_gate_op16), e.iret_eip,
             unsigned(e.iret_cs), e.iret_eflags, e.cur_lin_nat, e.cur_lin,
             e.mem_addr, e.bd_addr, unsigned(e.mem_req), unsigned(e.mem_we),
             unsigned(e.mem_ack), unsigned(e.cur_size), unsigned(e.read_strobes),
             unsigned(e.write_strobes), e.mem_rdata, unsigned(e.esp_write_enable),
             e.esp_write_data, bytes);
    }

    std::array<FaultRetireSnapshot, retire_capacity> retires_{};
    std::array<FaultCoreEdge, edge_capacity> edges_{};
    size_t retire_next_ = 0, retire_size_ = 0, edge_next_ = 0, edge_size_ = 0, bytes_ = 0;
    FaultCoreEdge pre_edge_{}, previous_edge_{};
    FaultRingOptions options_{};
    FILE *output_ = nullptr;
    uint64_t epoch_ = 0;
    unsigned events_ = 0;
    uint8_t previous_count_ = 0;
    bool failed_ = false, count_known_ = false, previous_edge_known_ = false, reset_held_ = false;
};

static_assert(sizeof(RetireFaultRing) < 128 * 1024, "fault observer memory must stay bounded");

} // namespace ven_host
#endif
