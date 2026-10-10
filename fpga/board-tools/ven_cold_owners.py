"""Fence cold-run cleanup by the actual systemd invocation and native PID.

Callbacks operate only on caller-owned, unique service names. This is a
fail-closed identity check, not an atomic systemd transaction: the caller
still needs exclusive control of the board and service names throughout.
No process, clock, reset, scan selector or guest RAM is touched by this module.
"""
import re


class OwnershipError(RuntimeError):
    pass


class OwnedServices:
    def __init__(self, initial, query, stop, signal):
        self.initial = {name: dict(state) for name,state in initial.items()}
        self.query, self.stop_callback, self.signal_callback = query, stop, signal
        self.stopped = set()
        if not self.initial:
            raise OwnershipError('no admitted native owners')
        for name,state in self.initial.items():
            if not re.fullmatch(r'[A-Za-z0-9_.@-]+\.service', name):
                raise OwnershipError('invalid service name')
            if state.get('Id') != name or not re.fullmatch(r'[0-9a-f]{32}',state.get('InvocationID','')):
                raise OwnershipError('missing native invocation identity')
            if self.pid(state) <= 0 or state.get('SubState') != 'running':
                raise OwnershipError('owner was not observed running')

    @staticmethod
    def pid(state):
        value = state.get('MainPID')
        if not isinstance(value,str) or not re.fullmatch(r'0|[1-9][0-9]*',value):
            raise OwnershipError('invalid MainPID')
        return int(value)

    @classmethod
    def quiescent(cls,state):
        return cls.pid(state) == 0 and state.get('TasksCurrent') in ('0','[not set]') and (
            state.get('ActiveState') in ('inactive','failed') or
            (state.get('ActiveState'),state.get('SubState')) == ('active','exited'))

    def observe(self,name):
        old = self.initial[name]
        now = self.query(name)
        if now.get('Id') != name:
            raise OwnershipError('missing or replaced service '+name)
        identity = now.get('InvocationID')
        # Successful systemctl stop can clear InvocationID. Admit that shape
        # only after our own checked stop, with no PID or remaining tasks.
        stopped_empty = name in self.stopped and identity == '' and self.quiescent(now)
        if identity != old['InvocationID'] and not stopped_empty:
            raise OwnershipError('replaced invocation '+name)
        pid = self.pid(now)
        if pid and pid != self.pid(old):
            raise OwnershipError('replaced native PID '+name)
        return dict(now)

    def signal(self,name,signal):
        state = self.observe(name)
        if self.pid(state):
            self.signal_callback(name,signal)
        return self.observe(name)

    def stop(self,name):
        state = self.observe(name)
        if not self.quiescent(state):
            self.stop_callback(name)
            self.stopped.add(name)  # Only after a successful synchronous stop.
        state = self.observe(name)
        if not self.quiescent(state):
            raise OwnershipError('owned service has not quiesced '+name)
        return state

    def require_closed(self):
        states = {name: self.observe(name) for name in self.initial}
        if not all(self.quiescent(state) for state in states.values()):
            raise OwnershipError('native workers remain before hardware mutation')
        return states

    def close_all(self):
        errors = []
        for name in self.initial:
            try:
                self.stop(name)
            except Exception as error:
                # Still stop another admitted owner; never stop a replacement.
                errors.append(name+': '+str(error))
        if errors:
            raise OwnershipError('; '.join(errors))
        return self.require_closed()
