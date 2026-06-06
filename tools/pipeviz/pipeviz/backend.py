# Copyright 2026 Anhang Li (AL-255, thelithcore@gmail.com)
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""ctypes binding to libventium_viz.so — the Verilator backend.

Mirrors the C structs in ventium_viz.h field-for-field (native alignment). The
constructor cross-checks ctypes.sizeof against the C sizeof (vv_sizeof) so an
ABI drift fails loudly instead of returning garbled state.
"""
import ctypes as C
import os

u8, u16, u32, u64 = C.c_uint8, C.c_uint16, C.c_uint32, C.c_uint64

NSEG, NGPR, NFPR, IBUF, TLB_ENTRIES, LINE = 6, 8, 8, 16, 16, 32
IC_SETS = DC_SETS = 128
WAYS = 2
MAX_CLINES = IC_SETS * WAYS          # 256

# segment / GPR labels (RTL index order)
SEG_NAMES = ["CS", "SS", "DS", "ES", "FS", "GS"]
GPR_NAMES = ["EAX", "ECX", "EDX", "EBX", "ESP", "EBP", "ESI", "EDI"]


class VVState(C.Structure):
    _fields_ = [
        ("clk", u64), ("core_cyc", u32), ("state", u32), ("cpu_hung", u8),
        ("eip", u32), ("flin", u32), ("next_eip", u32), ("q_pc", u32), ("q_pc2", u32),
        ("fetch_word", u8), ("ibuf", u8 * IBUF),
        ("gpr", u32 * NGPR), ("eflags", u32),
        ("seg_sel", u16 * NSEG), ("seg_base", u32 * NSEG),
        ("seg_limit", u32 * NSEG), ("seg_attr", u8 * NSEG),
        ("cr0", u32), ("cr2", u32), ("cr3", u32), ("cr4", u32),
        ("sys_mode", u8), ("cpl", u8), ("smm_active", u8),
        ("stall_cnt", u8), ("mispred_bubbles", u8), ("pending_mem_pen", u8),
        ("pipe_pair", u8), ("pipe_pair_ok", u8),
        ("pf_word", u8), ("pf_fill_addr", u32), ("pf_fill_way", u8),
        ("walk_for_d", u8), ("walk_ret_state", u32),
        ("fp_occ_pending", u8), ("fp_issue_cyc", u32), ("fp_ready_cyc", u32),
        ("ftop", u8), ("fptag", u8), ("fctrl", u16), ("fstat", u16),
        ("fpr", (u8 * 10) * NFPR),
        ("ud_len", u8), ("vd_len", u8),
        ("ud_simple", u8), ("ud_is_load", u8), ("ud_is_branch", u8),
        ("ud_is_fp", u8), ("ud_pairs_first", u8),
        ("vd_simple", u8), ("vd_is_load", u8), ("vd_is_branch", u8),
        ("vd_is_fp", u8), ("vd_pairs_second", u8),
        ("ud_aluop", u8), ("vd_aluop", u8), ("ud_fp_kind", u8), ("vd_fp_kind", u8),
    ]


class VVTlb(C.Structure):
    _fields_ = [("valid", u8), ("big", u8), ("dirty", u8), ("perm", u8),
                ("vpn", u32), ("pfn", u32)]


class VVCline(C.Structure):
    _fields_ = [("set", u8), ("way", u8), ("valid", u8), ("lru", u8),
                ("tag", u32), ("data", u8 * LINE)]


class VVRetire(C.Structure):
    _fields_ = [("n", u64), ("cyc", u64), ("pc", u32), ("eflags", u32),
                ("gpr", u32 * NGPR), ("seg", u16 * NSEG),
                ("pipe", u8), ("paired", u8), ("nbytes", u8), ("bytes", u8 * 16),
                ("x87_valid", u8), ("fctrl", u16), ("fstat", u16), ("ftag", u16),
                ("st", (u8 * 10) * NFPR)]


class VVCycle(C.Structure):
    _fields_ = [("cyc", u64), ("state", u32), ("eip", u32), ("flin", u32),
                ("stall_cnt", u8), ("mispred_bubbles", u8), ("pending_mem_pen", u8),
                ("fp_occ_pending", u8), ("pf_word", u8), ("retU", u8), ("retV", u8),
                ("nU", u64), ("nV", u64), ("pcU", u32), ("pcV", u32)]


def _default_lib_path():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(here, "libventium_viz.so")


class Backend:
    """Thin pythonic wrapper around the libventium_viz handle."""

    def __init__(self, libpath=None):
        libpath = libpath or _default_lib_path()
        if not os.path.exists(libpath):
            raise FileNotFoundError(
                f"{libpath} not found — run tools/pipeviz/build.sh first.")
        self.lib = C.CDLL(libpath)
        self._decl()
        self._abi_check()
        self.h = self.lib.vv_create()
        if not self.h:
            raise RuntimeError("vv_create() returned NULL")

    # ---- ctypes prototypes ----
    def _decl(self):
        L = self.lib
        L.vv_create.restype = C.c_void_p
        L.vv_destroy.argtypes = [C.c_void_p]
        L.vv_load_image.argtypes = [C.c_void_p, C.c_char_p, u32]
        L.vv_load_image.restype = C.c_long
        L.vv_load_bytes.argtypes = [C.c_void_p, C.POINTER(u8), u32, u32]
        L.vv_mem_read8.argtypes = [C.c_void_p, u32]
        L.vv_mem_read8.restype = u8
        L.vv_mem_read.argtypes = [C.c_void_p, u32, C.POINTER(u8), u32]
        L.vv_sizeof.argtypes = [C.c_int]
        L.vv_sizeof.restype = u32
        L.vv_reset.argtypes = [C.c_void_p, u32, u32, C.c_int, C.c_int]
        L.vv_step.argtypes = [C.c_void_p, u32, C.c_int]
        L.vv_step.restype = u64
        L.vv_is_done.argtypes = [C.c_void_p]
        L.vv_is_done.restype = C.c_int
        L.vv_get_state.argtypes = [C.c_void_p, C.POINTER(VVState)]
        L.vv_get_tlb.argtypes = [C.c_void_p, C.c_int, C.POINTER(VVTlb)]
        L.vv_get_tlb.restype = C.c_int
        L.vv_get_icache.argtypes = [C.c_void_p, C.POINTER(VVCline), C.c_int]
        L.vv_get_icache.restype = C.c_int
        L.vv_get_dcache.argtypes = [C.c_void_p, C.POINTER(VVCline), C.c_int]
        L.vv_get_dcache.restype = C.c_int
        L.vv_retire_count.argtypes = [C.c_void_p]
        L.vv_retire_count.restype = u64
        L.vv_get_retires.argtypes = [C.c_void_p, u64, C.POINTER(VVRetire), C.c_int]
        L.vv_get_retires.restype = C.c_int
        L.vv_cycle_count.argtypes = [C.c_void_p]
        L.vv_cycle_count.restype = u64
        L.vv_get_cycles.argtypes = [C.c_void_p, u64, C.POINTER(VVCycle), C.c_int]
        L.vv_get_cycles.restype = C.c_int
        L.vv_state_name.argtypes = [u32]
        L.vv_state_name.restype = C.c_char_p

    def _abi_check(self):
        want = {0: VVState, 1: VVTlb, 2: VVCline, 3: VVRetire, 4: VVCycle}
        for which, cls in want.items():
            c_sz = self.lib.vv_sizeof(which)
            py_sz = C.sizeof(cls)
            if c_sz != py_sz:
                raise RuntimeError(
                    f"ABI mismatch on {cls.__name__}: C={c_sz} python={py_sz}. "
                    f"ventium_viz.h and backend.py drifted.")

    # ---- lifecycle ----
    def close(self):
        if getattr(self, "h", None):
            self.lib.vv_destroy(self.h)
            self.h = None

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    # ---- driving ----
    def load_image(self, path, addr):
        return self.lib.vv_load_image(self.h, str(path).encode(), addr)

    def load_bytes(self, data: bytes, addr):
        buf = (u8 * len(data)).from_buffer_copy(data)
        self.lib.vv_load_bytes(self.h, buf, len(data), addr)

    def mem_read(self, addr, n):
        buf = (u8 * n)()
        self.lib.vv_mem_read(self.h, addr, buf, n)
        return bytes(buf)

    def reset(self, entry, esp, cycle_mode=1, system=0):
        self.lib.vv_reset(self.h, entry, esp, int(cycle_mode), int(system))

    def step(self, n, stop_on_retire=False):
        return int(self.lib.vv_step(self.h, n, 1 if stop_on_retire else 0))

    def is_done(self):
        return bool(self.lib.vv_is_done(self.h))

    # ---- readers ----
    def state(self):
        s = VVState()
        self.lib.vv_get_state(self.h, C.byref(s))
        return s

    def tlb(self, is_d):
        arr = (VVTlb * TLB_ENTRIES)()
        self.lib.vv_get_tlb(self.h, 1 if is_d else 0, arr)
        return arr

    def icache(self):
        arr = (VVCline * MAX_CLINES)()
        n = self.lib.vv_get_icache(self.h, arr, MAX_CLINES)
        return arr[:n]

    def dcache(self):
        arr = (VVCline * MAX_CLINES)()
        n = self.lib.vv_get_dcache(self.h, arr, MAX_CLINES)
        return arr[:n]

    def retire_count(self):
        return int(self.lib.vv_retire_count(self.h))

    def get_retires(self, since_n, maxn):
        arr = (VVRetire * maxn)()
        n = self.lib.vv_get_retires(self.h, since_n, arr, maxn)
        return arr[:n]

    def cycle_count(self):
        return int(self.lib.vv_cycle_count(self.h))

    def get_cycles(self, since_cyc, maxn):
        arr = (VVCycle * maxn)()
        n = self.lib.vv_get_cycles(self.h, since_cyc, arr, maxn)
        return arr[:n]

    def state_name(self, s):
        return self.lib.vv_state_name(s).decode()
