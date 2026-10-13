"""Exact two-file obsolete-x87 no-op repair; no FP command/state update.

Recognize only DB E0/E1/E4. Keep x87 classification for #NM; dispatch the
no-write integer completion before #MF checking instead of aliasing FNOP.
"""
import hashlib

PARENTS = {
    'decode_stages.sv': '04fb99e7e0f0c710124ccc3d9efea0d6a3fff57ea02f1037e4c455f56d7df576',
    'core_fetch_decode.svh': '50e6e72a6e9fc106659de44408106567564b3174ab60538991b25eef50e9ca71',
}


def transform(source, name):
    if hashlib.sha256(source.encode()).hexdigest() != PARENTS[name]:
        raise ValueError('obsolete-x87 source drift/reapplication: '+name)
    if name == 'decode_stages.sv':
        before = "                  8'hE2: d_fxop=FX_FNCLEX;\n"
        after = """                  // P5 obsolete 8087/287 controls: #NM still applies, but
                  // no FP command, pointer update, or pending-#MF test. Only
                  // these legal x87 forms intentionally retain FX_NONE.
                  8'hE0, 8'hE1, 8'hE4: d_fxop=FX_NONE;
""" + before
    else:
        before = "          else if (d_is_fwait && creg0[1] && creg0[3]) begin\n"
        # Keep the branch beside x87 #NM, before FWAIT/#MF and shared dispatch.
        # S_EXEC uses the default no-write K_ALU packet and common debug retire.
        after = """          else if (d_is_x87 && d_fxop == FX_NONE) begin
            // FENI/FDISI/FSETPM: #NM was checked above. Unlike FNOP, do
            // not check pending #MF or touch FPU state (including pointers).
            state <= S_EXEC;
          end
""" + before
    if source.count(before) != 1:
        raise ValueError('obsolete-x87 ambiguous anchor: '+name)
    return source.replace(before, after)
