"""Run the unchanged held-read corpus with case-unique, non-ephemeral GDB ports.

The first cofactor attempt lost a QEMU handshake (ConnectionResetError) before
the failing case reached either model. Keep that failed run. Avoid port reuse
between concurrent golden workers without changing images or comparisons.
"""
import os
from pathlib import Path
import socket
import sys

import run_mc_address_held as original


def main():
    source = Path(original.__file__).resolve()
    text = source.read_text()
    old = """        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
"""
    assert text.count(old) == 1
    low,high = map(int,Path('/proc/sys/net/ipv4/ip_local_port_range').read_text().split())
    assert 27023 < low or 27000 > high
    sockets = []
    try:
        for port in range(27000,27024):
            sock = socket.socket(); sockets.append(sock)
            sock.bind(('127.0.0.1',port))
    finally:
        for sock in sockets: sock.close()
    text = text.replace(old,"        port = 27000 + 4*kind + 2*reloc + int(offset == 31)\n")
    anchor = '    pins={}\n'
    assert text.count(anchor) == 1
    text = text.replace(anchor,anchor+f'    pins[{str(source)!r}]=sha({str(source)!r})\n')
    assert os.environ['VENTIUM_BUILD_SCOPE_PROFILE'] == 'ipc_parallel32'
    exec(compile(text,str(Path(__file__)),'exec'),{'__file__':str(Path(__file__)),'__name__':'__main__'})


if __name__ == '__main__': main()
