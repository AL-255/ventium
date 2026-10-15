"""Private, process-authenticated GDB transport for locally launched QEMU.

The TCP RSP client remains usable for explicit remote debugging. Golden producers
must instead connect to their own child, never an unrelated listener/retry port.
Linux SO_PEERCRED is checked before sending even the first RSP byte.
"""
import os
import socket
import struct
import subprocess
import tempfile
import time


class OwnedGDBError(RuntimeError):
    pass


class OwnedGDBEndpoint:
    def __init__(self):
        if not hasattr(socket, 'SO_PEERCRED'):
            raise OwnedGDBError('owned QEMU transport requires Linux SO_PEERCRED')
        self.directory = tempfile.TemporaryDirectory(prefix='ventium-gdb-')
        try:
            self.fd = os.open(self.directory.name, os.O_RDONLY | os.O_DIRECTORY)
        except BaseException:
            self.directory.cleanup()
            raise
        # TMPDIR may exceed sockaddr_un.sun_path. This short procfs alias still
        # creates the socket in the requested TMPDIR, not on the root filesystem.
        self.path = f'/proc/{os.getpid()}/fd/{self.fd}/gdb'

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
            self.directory.cleanup()

    def connect(self, proc, timeout):
        deadline = time.monotonic() + timeout
        last = None
        while time.monotonic() < deadline:
            code = proc.poll()
            if code is not None:
                raise OwnedGDBError(f'QEMU pid {proc.pid} exited before GDB connection: {code}')
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                sock.settimeout(max(0.001, deadline - time.monotonic()))
                sock.connect(self.path)
                cred = struct.unpack('3i', sock.getsockopt(
                    socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize('3i')))
                expected = (proc.pid, os.geteuid(), os.getegid())
                if cred != expected or proc.poll() is not None:
                    raise OwnedGDBError(f'GDB peer {cred} does not match live QEMU {expected}')
                return sock
            except (FileNotFoundError, ConnectionRefusedError) as error:
                last = error
                sock.close()
                time.sleep(min(0.01, max(0, deadline - time.monotonic())))
            except BaseException:
                sock.close()
                raise
        raise OwnedGDBError(f'QEMU pid {proc.pid} did not open its private GDB socket: {last}')


def start_owned_qemu(cmd, *, gdb_option, **kwargs):
    """Start exactly one QEMU; retain its private endpoint until it is reaped.

    An exec-only launcher such as setarch is supported (PID stays unchanged).
    A forking wrapper fails the credential check instead of silently trusting it.
    """
    cmd = list(cmd)
    # These generators place their managed option before guest arguments.
    # Do not count matching guest flags (a program may legitimately take -g).
    # A later QEMU-side override cannot redirect our authenticated connection:
    # it will fail waiting for this endpoint rather than connect to that port.
    if gdb_option not in ('-g', '-gdb') or gdb_option not in cmd:
        raise OwnedGDBError('missing managed QEMU GDB option')
    index = cmd.index(gdb_option) + 1
    if index >= len(cmd):
        raise OwnedGDBError('missing QEMU GDB argument')
    endpoint = OwnedGDBEndpoint()
    try:
        cmd[index] = (endpoint.path if gdb_option == '-g' else
                      f'unix:{endpoint.path},server=on,wait=off')
        proc = subprocess.Popen(cmd, **kwargs)
    except BaseException:
        endpoint.close()
        raise
    proc.owned_gdb_endpoint = endpoint
    return proc


def connect_owned_qemu(proc, timeout):
    return proc.owned_gdb_endpoint.connect(proc, timeout)


def release_owned_endpoint(proc):
    endpoint = getattr(proc, 'owned_gdb_endpoint', None)
    if endpoint is not None:
        if proc.poll() is None:
            raise OwnedGDBError('refusing to release a live QEMU endpoint')
        endpoint.close()
