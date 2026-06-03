// verif/tb/trace_writer.h
//
// Tiny shared object that owns the open .vtrace file and the retire counter.
// tb_main.cpp constructs it (opens the file, writes the header), exposes it to
// dpi_retire.cpp via the ventium::g_trace global, and dpi_retire.cpp appends
// one func-mode record per vtm_retire call. Header/record formats are pinned by
// docs/trace-format.md §1/§2 and verif/diff/tracefmt.py.
//
// Kept header-only and dependency-free so both translation units agree on the
// layout without a separate .cpp. This is the only file shared between the two
// owned source files of Producer C.
#ifndef VENTIUM_TRACE_WRITER_H
#define VENTIUM_TRACE_WRITER_H

#include <cstdint>
#include <cstdio>
#include <string>

namespace ventium {

class TraceWriter {
public:
    TraceWriter() = default;
    ~TraceWriter() { close(); }

    // Open the output file and emit the header line. The header matches
    // tracefmt.header("rtl","func",x87=false,...) — i.e.
    //   {"vtrace":1,"producer":"rtl","mode":"func","x87":false,"note":"..."}
    // Returns true on success.
    bool open(const std::string& path, const std::string& note) {
        fp_ = std::fopen(path.c_str(), "wb");
        if (!fp_) return false;
        // note is free-form (trace-format.md §1) and ignored by the comparator;
        // it must not contain a double-quote — tb_main passes only simple text.
        std::fprintf(fp_,
            "{\"vtrace\":1,\"producer\":\"rtl\",\"mode\":\"func\","
            "\"x87\":false,\"note\":\"%s\"}\n",
            note.c_str());
        return true;
    }

    void close() {
        if (fp_) {
            std::fflush(fp_);
            std::fclose(fp_);
            fp_ = nullptr;
        }
    }

    bool   ok()  const { return fp_ != nullptr; }
    FILE*  fp()  const { return fp_; }

    // Bookkeeping driven by dpi_retire.cpp on each emitted record.
    void     note_retire() { ++retired_; }
    uint64_t retired() const { return retired_; }

private:
    FILE*    fp_      = nullptr;
    uint64_t retired_ = 0;
};

// Defined in dpi_retire.cpp; set by tb_main before clocking begins.
extern TraceWriter* g_trace;

}  // namespace ventium

#endif  // VENTIUM_TRACE_WRITER_H
