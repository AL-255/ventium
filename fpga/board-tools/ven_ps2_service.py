#!/usr/bin/env python3
"""Single-owner board mouse service and same-UID local input client.

Start `serve` while the actual guest is held in reset, then cold boot through
the normal launcher. This program never resets/steps the CPU or touches RAM.
Input acknowledgement means queued sensor input, NOT wire/guest delivery.
On failure/exit, retain the guest state for diagnosis; fresh attach needs reset.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import stat
import struct
import time

from ven_ps2_mailbox_host import Adapter, MailboxError
from ven_ps2_mmio import MMIO


def response(host, payload):
    """Validate one bounded request before any policy mutation."""
    if len(payload) > 512:
        return dict(ok=False, error='request exceeds 512 bytes')
    try:
        request = json.loads(payload)
        if type(request) is not dict:
            raise ValueError('request must be an object')
        op = request.get('op')
        if op == 'status' and set(request) == {'op'}:
            return dict(ok=True, armed=host.armed, generation=host.generation,
                tx_sequence=host.tx_sequence, rx_sequence=host.rx_sequence,
                pending_command=host.pending['kind'] if host.pending else None,
                tx_owned=host.flight is not None, delivery_confirmed=False)
        if op != 'input' or not set(request) <= {'op', 'dx', 'dy', 'buttons'}:
            raise ValueError('expected status or input with dx/dy/buttons')
        if set(request) == {'op'}:
            raise ValueError('input requires a sensor value')
        dx, dy, buttons = request.get('dx', 0), request.get('dy', 0), request.get('buttons')
        if type(dx) is not int or type(dy) is not int or max(abs(dx), abs(dy)) > 32767:
            raise ValueError('dx/dy must be integer sensor counts within +/-32767')
        if 'buttons' in request and (type(buttons) is not int or not 0 <= buttons <= 7):
            raise ValueError('buttons must be an integer in 0..7')
        host.input(dx, dy, buttons)
        return dict(ok=True, queued=True, delivery_confirmed=False)
    except (ValueError, UnicodeError, OverflowError, MailboxError) as error:
        return dict(ok=False, error=str(error))


class Endpoint:
    """Bounded nonblocking Unix seqpacket endpoint; no slow-client stalls."""
    def __init__(self, path, host):
        self.path, self.host = Path(path), host
        self.selector = selectors.DefaultSelector()
        self.clients = {}
        self.identity = None
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
        try:
            # Never unlink an existing socket: it may belong to a live service.
            self.listener.bind(str(self.path))
            info = self.path.lstat()
            self.identity = (info.st_dev, info.st_ino)
            self.path.chmod(0o600)
            self.listener.listen(4)
            self.listener.setblocking(False)
            self.selector.register(self.listener, selectors.EVENT_READ)
        except BaseException:
            self.close()
            raise

    def _close_client(self, client):
        self.selector.unregister(client)
        self.clients.pop(client)
        client.close()

    def step(self, timeout=0.001):
        for key, mask in self.selector.select(timeout):
            if key.fileobj is self.listener:
                try:
                    client, _ = self.listener.accept()
                except BlockingIOError:
                    continue
                uid = struct.unpack('3i', client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
                if uid != os.geteuid() or len(self.clients) >= 4:
                    client.close()
                    continue
                client.setblocking(False)
                self.clients[client] = dict(deadline=time.monotonic()+1, reply=None)
                self.selector.register(client, selectors.EVENT_READ)
                continue
            client = key.fileobj
            state = self.clients[client]
            try:
                if mask & selectors.EVENT_READ:
                    payload = client.recv(513)
                    if not payload:
                        self._close_client(client)
                        continue
                    state['reply'] = json.dumps(response(self.host, payload)).encode()
                    self.selector.modify(client, selectors.EVENT_WRITE)
                elif mask & selectors.EVENT_WRITE:
                    # SOCK_SEQPACKET sends one complete record or fails.
                    if client.send(state['reply']) != len(state['reply']):
                        raise OSError('incomplete seqpacket reply')
                    self._close_client(client)
            except BlockingIOError:
                pass
            except (BrokenPipeError, ConnectionResetError):
                self._close_client(client)
        now = time.monotonic()
        for client, state in list(self.clients.items()):
            if now >= state['deadline']:
                self._close_client(client)

    def close(self):
        for client in list(self.clients):
            self._close_client(client)
        self.selector.close()
        self.listener.close()
        if self.identity is not None:
            try:
                info = self.path.lstat()
                if stat.S_ISSOCK(info.st_mode) and (info.st_dev, info.st_ino) == self.identity:
                    self.path.unlink()
            except FileNotFoundError:
                pass
            self.identity = None


def serve(path, library=None):
    stopping = False
    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True
    previous = {number:signal.signal(number, stop) for number in (signal.SIGTERM, signal.SIGINT)}
    try:
        with MMIO(library) as io:
            host = Adapter(io.read32, io.write32)
            endpoint = Endpoint(path, host)
            try:
                print(json.dumps(dict(event='attached_held_reset', socket=str(path),
                    generation=host.generation, pid=os.getpid())), flush=True)
                last = None
                while not stopping:
                    result = host.poll(time.monotonic_ns())
                    if result == 'needs_reset':
                        raise MailboxError('mailbox exhausted; operator reset required')
                    if result in ('reset', 'armed') and result != last:
                        print(json.dumps(dict(event=result, generation=host.generation)), flush=True)
                    last = result
                    endpoint.step()
            finally:
                endpoint.close()
                print(json.dumps(dict(event='stopped', guest_reset_written=False,
                    pending_command=host.pending['kind'] if host.pending else None,
                    tx_owned=host.flight is not None, fresh_attach_requires_reset=True)), flush=True)
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--socket', type=Path, default=Path('/run/ventium-ps2-mouse.sock'))
    sub = parser.add_subparsers(dest='operation', required=True)
    server = sub.add_parser('serve')
    server.add_argument('--library', type=Path)
    sub.add_parser('status')
    move = sub.add_parser('input')
    move.add_argument('--dx', type=int)
    move.add_argument('--dy', type=int)
    move.add_argument('--buttons', type=int)
    args = parser.parse_args()
    if args.operation == 'serve':
        serve(args.socket, args.library)
        return 0
    request = dict(op=args.operation)
    if args.operation == 'input':
        request.update({k:getattr(args, k) for k in ('dx', 'dy', 'buttons') if getattr(args, k) is not None})
    with socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET) as client:
        client.settimeout(2)
        client.connect(str(args.socket))
        client.sendall(json.dumps(request).encode())
        answer = json.loads(client.recv(1024))
    print(json.dumps(answer), flush=True)
    return 0 if answer.get('ok') else 1


if __name__ == '__main__':
    raise SystemExit(main())
