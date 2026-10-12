"""Ordered board MMIO callbacks for Adapter; no reset or guest RAM accesses.

Build the sibling C file as an AArch64 shared library. A fixture library is
rejected, and no caller-selected physical address/device/lock is accepted.
The calling service must keep this object alive, use one thread, and hold the
guest in reset through Adapter construction. Fabric replacement is forbidden
while owned. Closing/reopening does NOT reset the policy or allow live attach.
"""
import ctypes
import os
from pathlib import Path
import threading


class MMIO:
    def __init__(self, library=None):
        self._owner = (os.getpid(), threading.get_ident())
        self._handle = None
        self._lib = ctypes.CDLL(str(Path(library or Path(__file__).with_name('libven_ps2_mmio.so')).resolve(strict=True)),
                                use_errno=True)
        self._lib.ven_ps2_mmio_fixture_build.argtypes = []
        self._lib.ven_ps2_mmio_fixture_build.restype = ctypes.c_uint
        if self._lib.ven_ps2_mmio_fixture_build():
            raise RuntimeError('host fixture library cannot be used for physical MMIO')
        self._lib.ven_ps2_mmio_open.argtypes = []
        self._lib.ven_ps2_mmio_open.restype = ctypes.c_void_p
        self._lib.ven_ps2_mmio_close.argtypes = [ctypes.c_void_p]
        self._lib.ven_ps2_mmio_close.restype = None
        self._lib.ven_ps2_mmio_read.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                               ctypes.POINTER(ctypes.c_uint32)]
        self._lib.ven_ps2_mmio_read.restype = ctypes.c_int
        self._lib.ven_ps2_mmio_write.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint32]
        self._lib.ven_ps2_mmio_write.restype = ctypes.c_int
        self._handle = self._lib.ven_ps2_mmio_open()
        if not self._handle:
            self._error()

    @staticmethod
    def _error():
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number))

    def _check(self, index):
        if not self._handle or self._owner != (os.getpid(), threading.get_ident()):
            raise RuntimeError('closed, forked or foreign-thread MMIO owner')
        if type(index) is not int or not 0 <= index <= 10:
            raise ValueError('invalid mailbox register index')

    def read32(self, index):
        self._check(index)
        value = ctypes.c_uint32()
        if self._lib.ven_ps2_mmio_read(self._handle, index, ctypes.byref(value)):
            self._error()
        return value.value

    def write32(self, index, value):
        self._check(index)
        if type(value) is not int or not 0 <= value <= 0xffffffff:
            raise ValueError('invalid unsigned 32-bit mailbox value')
        if self._lib.ven_ps2_mmio_write(self._handle, index, value):
            self._error()

    def close(self):
        if self._owner != (os.getpid(), threading.get_ident()):
            raise RuntimeError('only the owning thread/process may close MMIO')
        if self._handle:
            self._lib.ven_ps2_mmio_close(self._handle)
            self._handle = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
