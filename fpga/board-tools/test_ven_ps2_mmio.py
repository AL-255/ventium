"""Native file-backed backend checks; NOT device-memory ordering/board proof.

Set VEN_PS2_MMIO_TEST_LIB to a library compiled with VEN_PS2_MMIO_TEST.
Physical open is disabled in that library; the Python wrapper must reject it.
"""
import ctypes
import errno
import os
from pathlib import Path
import struct
import tempfile
import threading
import unittest
from unittest.mock import MagicMock, patch

import ven_ps2_mmio as mmio


class NativeBackendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.library = Path(os.environ['VEN_PS2_MMIO_TEST_LIB']).resolve(strict=True)
        cls.lib = ctypes.CDLL(str(cls.library), use_errno=True)
        cls.lib.ven_ps2_mmio_open_fixture.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
        cls.lib.ven_ps2_mmio_open_fixture.restype = ctypes.c_void_p
        cls.lib.ven_ps2_mmio_open.argtypes = []
        cls.lib.ven_ps2_mmio_open.restype = ctypes.c_void_p
        cls.lib.ven_ps2_mmio_close.argtypes = [ctypes.c_void_p]
        cls.lib.ven_ps2_mmio_close.restype = None
        cls.lib.ven_ps2_mmio_read.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                              ctypes.POINTER(ctypes.c_uint32)]
        cls.lib.ven_ps2_mmio_read.restype = ctypes.c_int
        cls.lib.ven_ps2_mmio_write.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint32]
        cls.lib.ven_ps2_mmio_write.restype = ctypes.c_int

    def setUp(self):
        scratch = Path(os.environ['TMPDIR']).resolve(strict=True)
        self.assertEqual(scratch, Path('/home/yukidama/external/tmp').resolve(strict=True))
        self.temporary = tempfile.TemporaryDirectory(prefix='ps2-mmio-unit.', dir=scratch)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.memory, self.lock = self.root/'registers', self.root/'owner.lock'
        self.original = bytearray([0xa5] * os.sysconf('SC_PAGESIZE'))
        struct.pack_into('<I', self.original, 0x400, 0x50533201)
        for index in (1, 2, 5, 7, 8):
            struct.pack_into('<I', self.original, 0x400 + 16*index, 0x81000000+index)
        self.memory.write_bytes(self.original)

    def open(self):
        return self.lib.ven_ps2_mmio_open_fixture(os.fsencode(self.memory), os.fsencode(self.lock))

    def owned(self):
        handle = self.open()
        self.assertTrue(handle, ctypes.get_errno())
        self.addCleanup(self.lib.ven_ps2_mmio_close, handle)
        return handle

    def test_fixture_cannot_open_hardware_or_load_as_production(self):
        self.assertFalse(self.lib.ven_ps2_mmio_open())
        self.assertEqual(ctypes.get_errno(), errno.ENOTSUP)
        with self.assertRaisesRegex(RuntimeError, 'fixture'):
            mmio.MMIO(self.library)

    def test_capability_rejection_releases_lock_without_writes(self):
        self.original[0x400:0x404] = b'BAD!'
        self.memory.write_bytes(self.original)
        for _ in range(2):
            self.assertFalse(self.open())
            self.assertEqual(ctypes.get_errno(), errno.ENODEV)
        self.assertEqual(self.memory.read_bytes(), self.original)

    def test_exclusive_owner_and_close_reopens_same_lock_inode(self):
        first = self.open()
        self.assertTrue(first)
        try:
            inode = self.lock.stat().st_ino
            self.assertFalse(self.open())
            self.assertIn(ctypes.get_errno(), (errno.EAGAIN, errno.EWOULDBLOCK))
        finally:
            self.lib.ven_ps2_mmio_close(first)
        self.owned()
        self.assertEqual(self.lock.stat().st_ino, inode)

    def test_exact_read_lanes_and_no_side_effects(self):
        handle = self.owned()
        for index in (0, 1, 2, 5, 7, 8):
            value = ctypes.c_uint32()
            self.assertEqual(self.lib.ven_ps2_mmio_read(handle, index, ctypes.byref(value)), 0)
            expected = 0x50533201 if index == 0 else 0x81000000+index
            self.assertEqual(value.value, expected)
        self.assertEqual(self.memory.read_bytes(), self.original)

    def test_exact_write_lanes_preserve_adjacent_registers(self):
        handle = self.owned()
        for index, value in ((3, 0xffffffff), (4, 255), (6, 0x12345678), (9, 0xffffffff), (10, 3)):
            self.assertEqual(self.lib.ven_ps2_mmio_write(handle, index, value), 0)
            struct.pack_into('<I', self.original, 0x400+16*index, value)
            self.assertEqual(self.memory.read_bytes(), self.original)

    def test_invalid_registers_and_values_never_touch_memory(self):
        handle = self.owned()
        for index in (*range(16), 0x80000000, 0xffffffff):
            if index not in (0, 1, 2, 5, 7, 8):
                value = ctypes.c_uint32(0x1234)
                self.assertEqual(self.lib.ven_ps2_mmio_read(handle, index, ctypes.byref(value)), -1)
                self.assertEqual(ctypes.get_errno(), errno.EINVAL)
                self.assertEqual(value.value, 0x1234)
            if index not in (3, 4, 6, 9, 10):
                self.assertEqual(self.lib.ven_ps2_mmio_write(handle, index, 0), -1)
                self.assertEqual(ctypes.get_errno(), errno.EINVAL)
        for index, value in ((4, 256), (4, 0xffffffff), (10, 4), (10, 0xffffffff)):
            self.assertEqual(self.lib.ven_ps2_mmio_write(handle, index, value), -1)
            self.assertEqual(ctypes.get_errno(), errno.EINVAL)
        self.assertEqual(self.lib.ven_ps2_mmio_read(handle, 1, None), -1)
        self.assertEqual(ctypes.get_errno(), errno.EINVAL)
        self.assertEqual(self.memory.read_bytes(), self.original)

    def test_missing_owner_rejected(self):
        value = ctypes.c_uint32()
        self.assertEqual(self.lib.ven_ps2_mmio_read(None, 1, ctypes.byref(value)), -1)
        self.assertEqual(ctypes.get_errno(), errno.EPERM)
        self.assertEqual(self.lib.ven_ps2_mmio_write(None, 3, 0), -1)
        self.assertEqual(ctypes.get_errno(), errno.EPERM)
        self.lib.ven_ps2_mmio_close(None)

    def test_fork_cannot_access_or_unlock_parent(self):
        handle = self.owned()
        child = os.fork()
        if child == 0:
            value = ctypes.c_uint32()
            good = self.lib.ven_ps2_mmio_read(handle, 1, ctypes.byref(value)) == -1
            good = good and ctypes.get_errno() == errno.EPERM
            good = good and self.lib.ven_ps2_mmio_write(handle, 3, 0) == -1
            self.lib.ven_ps2_mmio_close(handle)
            os._exit(0 if good else 1)
        self.assertEqual(os.waitpid(child, 0), (child, 0))
        self.assertFalse(self.open())
        self.assertIn(ctypes.get_errno(), (errno.EAGAIN, errno.EWOULDBLOCK))

    def test_lock_symlink_and_hardlink_rejected(self):
        target = self.root/'unrelated'
        target.write_bytes(b'preserve')
        self.lock.symlink_to(target)
        self.assertFalse(self.open())
        self.assertEqual(ctypes.get_errno(), errno.ELOOP)
        self.lock.unlink()
        os.link(target, self.lock)
        self.assertFalse(self.open())
        self.assertEqual(ctypes.get_errno(), errno.EPERM)
        self.assertEqual(target.read_bytes(), b'preserve')

    def test_memory_symlink_and_short_mapping_rejected(self):
        target = self.root/'real-registers'
        self.memory.rename(target)
        self.memory.symlink_to(target)
        self.assertFalse(self.open())
        self.assertEqual(ctypes.get_errno(), errno.ELOOP)
        self.memory.unlink()
        self.memory.write_bytes(b'short')
        self.assertFalse(self.open())
        self.assertEqual(ctypes.get_errno(), errno.EINVAL)


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.lib = MagicMock()
        self.lib.ven_ps2_mmio_fixture_build.return_value = 0
        self.lib.ven_ps2_mmio_open.return_value = 1234
        self.lib.ven_ps2_mmio_write.return_value = 0
        with patch.object(mmio.ctypes, 'CDLL', return_value=self.lib):
            self.owner = mmio.MMIO(__file__)
        self.addCleanup(self.owner.close)

    def test_integer_validation_before_native_write(self):
        for index in (-1, 11, 1 << 32, True, 1.0):
            with self.assertRaises(ValueError): self.owner.write32(index, 0)
        for value in (-1, 1 << 32, True, 1.0):
            with self.assertRaises(ValueError): self.owner.write32(3, value)
        self.lib.ven_ps2_mmio_write.assert_not_called()
        self.owner.write32(3, 0xffffffff)
        self.lib.ven_ps2_mmio_write.assert_called_once_with(1234, 3, 0xffffffff)

    def test_native_error_and_idempotent_close(self):
        self.lib.ven_ps2_mmio_write.return_value = -1
        ctypes.set_errno(errno.EINVAL)
        with self.assertRaises(OSError) as caught: self.owner.write32(1, 0)
        self.assertEqual(caught.exception.errno, errno.EINVAL)
        self.owner.close(); self.owner.close()
        self.lib.ven_ps2_mmio_close.assert_called_once_with(1234)
        with self.assertRaises(RuntimeError): self.owner.read32(1)

    def test_foreign_thread_cannot_read_write_or_close(self):
        errors = []
        def attempt():
            for operation in (lambda: self.owner.read32(1), lambda: self.owner.write32(3, 0), self.owner.close):
                try: operation()
                except RuntimeError: errors.append(True)
        thread = threading.Thread(target=attempt)
        thread.start(); thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [True, True, True])
        self.lib.ven_ps2_mmio_read.assert_not_called()
        self.lib.ven_ps2_mmio_write.assert_not_called()
        self.lib.ven_ps2_mmio_close.assert_not_called()


if __name__ == '__main__':
    unittest.main()
