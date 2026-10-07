// Passive simulation-RAM observer. No DUT writes, evals, forced ACK or restore.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>

class ExceptionLogProbe {
    FILE* out_ = nullptr;
    bool captured_ = false;
public:
    ExceptionLogProbe() {
        const char* path = std::getenv("VEN_EXCEPTION_LOG_FILE");
        if (!path) return;
        out_ = std::fopen(path, "wx");
        if (!out_) std::abort();
    }
    template<class Memory> void sample(const Memory& mem, uint64_t cycle) {
        if (!out_ || captured_ || mem.read32(0x100) != 0x564c4f47u) return;
        captured_ = true;
        std::fprintf(out_, "{\"type\":\"record\",\"cycle\":%llu,\"physical\":256,\"words\":[",
                     (unsigned long long)cycle);
        for (unsigned i = 0; i < 26; ++i)
            std::fprintf(out_, "%s%u", i ? "," : "", mem.read32(0x100 + i * 4));
        std::fprintf(out_, "],\"passive\":true,\"scope\":\"simulation physical RAM; not caches/in-flight state\"}\n");
        if (std::fflush(out_) || std::ferror(out_)) std::abort();
    }
    void finish() {
        if (!out_) return;
        std::fprintf(out_, "{\"type\":\"complete\",\"record_seen\":%s}\n", captured_ ? "true" : "false");
        if (std::fflush(out_) || std::ferror(out_) || std::fclose(out_)) std::abort();
        out_ = nullptr;
    }
    ~ExceptionLogProbe() { if (out_) std::abort(); }
};
