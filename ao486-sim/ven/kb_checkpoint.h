#pragma once

#include <cstddef>

// Keyboard emitter state is deliberately not serialized.  A scripted run may
// only save after all events and scancode bytes have left the host-side emitter.
// Restoring with a script is never safe: it could inject the same keys twice.
inline bool kb_checkpoint_save_quiescent(bool has_script, bool started,
                                         std::size_t event_index,
                                         std::size_t event_count,
                                         std::size_t queued_bytes, int phase) {
    return !has_script || (started && event_index == event_count &&
                           queued_bytes == 0 && phase < 0);
}

inline bool kb_checkpoint_restore_supported(bool has_script) {
    return !has_script;
}
