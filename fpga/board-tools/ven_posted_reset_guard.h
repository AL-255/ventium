// Posted DDR survives guest reset. Hold the guest in reset, then wait for real
// AXI completion before overwriting RAM. Caller must exclusively own reset and
// scan controls for the entire cold initialization (not just this function).
#ifndef VEN_POSTED_RESET_GUARD_H
#define VEN_POSTED_RESET_GUARD_H
#include <stdint.h>

namespace ven_posted {
constexpr uint32_t control = 0x20, selector = 0x2a0, data = 0x2b0;
enum class DrainResult { ready, reset_not_held, bad_selector, contention,
                         unsupported, fault, timeout, sleep_failed };
inline const char *message(DrainResult r) {
    switch (r) {
    case DrainResult::ready: return "posted DDR drained with guest held in reset";
    case DrainResult::reset_not_held: return "guest reset is not exclusively held";
    case DrainResult::bad_selector: return "invalid debug selector readback";
    case DrainResult::contention: return "debug selector changed concurrently";
    case DrainResult::unsupported: return "posted-DDR capability missing or malformed";
    case DrainResult::fault: return "posted-DDR bridge reports a sticky AXI fault";
    case DrainResult::timeout: return "posted-DDR drain timed out";
    case DrainResult::sleep_failed: return "posted-DDR drain wait interrupted/failed";
    }
    return "unknown drain error";
}

// pause() waits one millisecond, returning false on failure. Bounded to 1000
// polls; even a permanently busy bridge cannot hang startup. Two clean samples
// separated by a wait also cover propagation of the registered guest reset.
// No queue cancellation, guest writes, clock changes, or error clear is allowed.
template<class Read, class Write, class Pause>
DrainResult wait_for_reset_drain(Read read, Write write, Pause pause) {
    if (read(control) != 1) return DrainResult::reset_not_held;
    const uint32_t previous = read(selector);
    if (previous > 127) return DrainResult::bad_selector;
    write(selector, 79);
    DrainResult result = DrainResult::timeout;
    unsigned clean_samples = 0;
    for (unsigned attempt = 0; attempt < 1000; ++attempt) {
        if (read(control) != 1) { result = DrainResult::reset_not_held; break; }
        if (read(selector) != 79) { result = DrainResult::contention; break; }
        if (!pause()) { result = DrainResult::sleep_failed; break; }
        if (read(control) != 1) { result = DrainResult::reset_not_held; break; }
        if (read(selector) != 79) { result = DrainResult::contention; break; }
        const uint32_t status = read(data);
        if (read(selector) != 79) { result = DrainResult::contention; break; }
        if (read(control) != 1) { result = DrainResult::reset_not_held; break; }
        if ((status & ~7u) != 0x50440000u || !(status & 2)) {
            result = DrainResult::unsupported; break;
        }
        if (status & 4) { result = DrainResult::fault; break; }
        clean_samples = (status & 1) ? clean_samples + 1 : 0;
        if (clean_samples == 2) { result = DrainResult::ready; break; }
    }
    // Restore only our selector; never overwrite a detected competing owner.
    if (read(selector) != 79) return DrainResult::contention;
    write(selector, previous);
    if (read(selector) != previous) return DrainResult::contention;
    if (read(control) != 1) return DrainResult::reset_not_held;
    return result;
}
} // namespace ven_posted
#endif
