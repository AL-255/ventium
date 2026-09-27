#include "kb_checkpoint.h"

#include <cassert>

int main() {
    // No script: the emitter is dormant and has no state to save or replay.
    assert(kb_checkpoint_save_quiescent(false, false, 0, 0, 0, -1));
    assert(kb_checkpoint_restore_supported(false));

    // Every intermediate phase must reject a save, including a pending event,
    // queued break byte and an in-flight final scancode bit.
    assert(!kb_checkpoint_save_quiescent(true, false, 0, 2, 0, -1));
    assert(!kb_checkpoint_save_quiescent(true, true, 1, 2, 0, -1));
    assert(!kb_checkpoint_save_quiescent(true, true, 2, 2, 1, -1));
    assert(!kb_checkpoint_save_quiescent(true, true, 2, 2, 0, 10));
    assert(kb_checkpoint_save_quiescent(true, true, 2, 2, 0, -1));

    // The guest's PS/2 state is serialized in RTL, but the host-side emitter
    // is not. A scripted restore must therefore remain forbidden.
    assert(!kb_checkpoint_restore_supported(true));
}
